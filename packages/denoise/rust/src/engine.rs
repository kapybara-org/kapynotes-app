//! Runs one ONNX graph, Ceva's DPDFNet-2 export, a frame at a time.
//!
//! A general runtime (tract) put 16.6 MB into every build for a graph that
//! uses 25 operators on float32 tensors whose shapes never change. This reads
//! the ONNX file itself, works out once at load everything that does not
//! depend on the input, and runs the rest with plain loops. Any operator or
//! attribute it does not implement is refused at load, so a different model
//! fails before a recording is touched rather than halfway through one.

use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq)]
pub struct Tensor {
    pub shape: Vec<usize>,
    pub data: Vec<f32>,
}

impl Tensor {
    pub fn new(shape: Vec<usize>, data: Vec<f32>) -> Self {
        debug_assert_eq!(shape.iter().product::<usize>(), data.len());
        Self { shape, data }
    }
}

#[derive(Clone)]
enum Value {
    F(Tensor),
    I(Vec<usize>, Vec<i64>),
}

impl Value {
    fn f(&self) -> Result<&Tensor, String> {
        match self {
            Value::F(t) => Ok(t),
            Value::I(..) => Err("int64 values where floats were expected".into()),
        }
    }

    fn ints(&self) -> Result<&[i64], String> {
        match self {
            Value::I(_, v) => Ok(v),
            Value::F(_) => Err("floats where int64 values were expected".into()),
        }
    }
}

// ---- Protocol buffers: just enough of the wire format to read an ONNX file.

enum Field<'a> {
    Int(u64),
    Bytes(&'a [u8]),
    Fixed32(u32),
    Fixed64,
}

struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn new(b: &'a [u8]) -> Self {
        Self { b, at: 0 }
    }

    fn varint(&mut self) -> Result<u64, String> {
        let mut v = 0u64;
        for shift in (0..64).step_by(7) {
            let byte = *self.b.get(self.at).ok_or("the file ends early")?;
            self.at += 1;
            v |= u64::from(byte & 0x7f) << shift;
            if byte & 0x80 == 0 {
                return Ok(v);
            }
        }
        Err("a malformed number".into())
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        let end = self.at.checked_add(n).filter(|e| *e <= self.b.len()).ok_or("the file ends early")?;
        let s = &self.b[self.at..end];
        self.at = end;
        Ok(s)
    }

    fn next(&mut self) -> Result<Option<(u64, Field<'a>)>, String> {
        if self.at >= self.b.len() {
            return Ok(None);
        }
        let key = self.varint()?;
        let field = match key & 7 {
            0 => Field::Int(self.varint()?),
            1 => {
                self.take(8)?;
                Field::Fixed64
            }
            2 => {
                let n = self.varint()? as usize;
                Field::Bytes(self.take(n)?)
            }
            5 => Field::Fixed32(u32::from_le_bytes(self.take(4)?.try_into().unwrap())),
            w => return Err(format!("wire type {w}")),
        };
        Ok(Some((key >> 3, field)))
    }
}

fn text(f: Field) -> Result<String, String> {
    match f {
        Field::Bytes(b) => String::from_utf8(b.to_vec()).map_err(|_| "text that is not UTF-8".into()),
        _ => Err("a malformed string".into()),
    }
}

fn push_ints(f: Field, out: &mut Vec<i64>) -> Result<(), String> {
    match f {
        Field::Int(v) => out.push(v as i64),
        Field::Bytes(b) => {
            let mut r = Reader::new(b);
            while r.at < b.len() {
                out.push(r.varint()? as i64);
            }
        }
        _ => return Err("a malformed list of integers".into()),
    }
    Ok(())
}

fn push_floats(f: Field, out: &mut Vec<f32>) -> Result<(), String> {
    match f {
        Field::Fixed32(v) => out.push(f32::from_bits(v)),
        Field::Bytes(b) if b.len() % 4 == 0 => {
            out.extend(b.chunks_exact(4).map(|c| f32::from_le_bytes(c.try_into().unwrap())))
        }
        _ => return Err("a malformed list of floats".into()),
    }
    Ok(())
}

#[derive(Clone)]
enum Attr {
    Int(i64),
    Float(f32),
    Ints(Vec<i64>),
    Text(String),
    Other,
}

struct RawNode {
    op: String,
    domain: String,
    inputs: Vec<String>,
    outputs: Vec<String>,
    attrs: HashMap<String, Attr>,
}

fn parse_attr(b: &[u8]) -> Result<(String, Attr), String> {
    let (mut name, mut kind) = (String::new(), 0);
    let (mut f, mut i, mut s, mut ints) = (0.0, 0, String::new(), Vec::new());
    let mut r = Reader::new(b);
    while let Some((n, field)) = r.next()? {
        match (n, field) {
            (1, v) => name = text(v)?,
            (2, Field::Fixed32(v)) => f = f32::from_bits(v),
            (3, Field::Int(v)) => i = v as i64,
            (4, v) => s = text(v)?,
            (8, v) => push_ints(v, &mut ints)?,
            (20, Field::Int(v)) => kind = v,
            _ => {}
        }
    }
    let attr = match kind {
        1 => Attr::Float(f),
        2 => Attr::Int(i),
        3 => Attr::Text(s),
        7 => Attr::Ints(ints),
        _ => Attr::Other,
    };
    Ok((name, attr))
}

fn parse_node(b: &[u8]) -> Result<RawNode, String> {
    let mut node = RawNode { op: String::new(), domain: String::new(), inputs: vec![], outputs: vec![], attrs: HashMap::new() };
    let mut r = Reader::new(b);
    while let Some((n, field)) = r.next()? {
        match n {
            1 => node.inputs.push(text(field)?),
            2 => node.outputs.push(text(field)?),
            4 => node.op = text(field)?,
            5 => {
                if let Field::Bytes(a) = field {
                    let (k, v) = parse_attr(a)?;
                    node.attrs.insert(k, v);
                }
            }
            7 => node.domain = text(field)?,
            _ => {}
        }
    }
    Ok(node)
}

fn parse_tensor(b: &[u8]) -> Result<(String, Value), String> {
    let (mut dims, mut kind, mut name) = (Vec::new(), 0, String::new());
    let (mut floats, mut ints, mut raw): (Vec<f32>, Vec<i64>, &[u8]) = (vec![], vec![], &[]);
    let mut r = Reader::new(b);
    while let Some((n, field)) = r.next()? {
        match (n, field) {
            (1, v) => push_ints(v, &mut dims)?,
            (2, Field::Int(v)) => kind = v,
            (4, v) => push_floats(v, &mut floats)?,
            (7, v) => push_ints(v, &mut ints)?,
            (8, v) => name = text(v)?,
            (9, Field::Bytes(v)) => raw = v,
            (14, Field::Int(1)) => return Err("weights stored outside the file".into()),
            _ => {}
        }
    }
    let shape: Vec<usize> = dims.iter().map(|d| *d as usize).collect();
    let count: usize = shape.iter().product();
    let value = match kind {
        1 => {
            if !raw.is_empty() {
                floats = raw.chunks_exact(4).map(|c| f32::from_le_bytes(c.try_into().unwrap())).collect();
            }
            if floats.len() != count {
                return Err(format!("{name} has {} values for {count}", floats.len()));
            }
            Value::F(Tensor::new(shape, floats))
        }
        7 => {
            if !raw.is_empty() {
                ints = raw.chunks_exact(8).map(|c| i64::from_le_bytes(c.try_into().unwrap())).collect();
            }
            if ints.len() != count {
                return Err(format!("{name} has {} values for {count}", ints.len()));
            }
            Value::I(shape, ints)
        }
        k => return Err(format!("{name} has element type {k}")),
    };
    Ok((name, value))
}

fn value_name(b: &[u8]) -> Result<String, String> {
    let mut r = Reader::new(b);
    while let Some((n, field)) = r.next()? {
        if n == 1 {
            return text(field);
        }
    }
    Err("a graph input with no name".into())
}

// ---- Operators.

#[derive(Clone, Copy)]
enum Unary {
    Identity,
    Relu,
    Sigmoid,
    Tanh,
    Sqrt,
    Log,
}

#[derive(Clone, Copy)]
enum Binary {
    Add,
    Sub,
    Mul,
    Div,
    Pow,
}

enum Op {
    Unary(Unary),
    Binary(Binary),
    Reshape { allow_zero: bool },
    Transpose(Option<Vec<usize>>),
    Slice,
    Split { axis: i64, outputs: usize },
    Squeeze,
    Unsqueeze,
    Concat { axis: i64 },
    Flatten { axis: i64 },
    Gather { axis: i64 },
    ReduceSum { keep: bool, noop_empty: bool },
    Conv { group: usize, pads: [usize; 4], strides: [usize; 2], dilations: [usize; 2] },
    Gemm { alpha: f32, beta: f32, trans_a: bool, trans_b: bool },
    MatMul,
    LayerNorm { axis: i64, epsilon: f32 },
    /// [transposed]: the weights were turned to input-major at load.
    Gru { hidden: usize, direction: Direction, transposed: bool },
}

#[derive(Clone, Copy, PartialEq)]
enum Direction {
    Forward,
    Reverse,
    Both,
}

fn sigmoid(x: f32) -> f32 {
    1.0 / (1.0 + (-x).exp())
}

fn build_op(n: &RawNode) -> Result<Op, String> {
    if !(n.domain.is_empty() || n.domain == "ai.onnx") {
        return Err(format!("{} from {}", n.op, n.domain));
    }
    let only = |names: &[&str]| -> Result<(), String> {
        match n.attrs.keys().find(|k| !names.contains(&k.as_str())) {
            Some(k) => Err(format!("{} with {k}", n.op)),
            None => Ok(()),
        }
    };
    let int = |k: &str, d: i64| match n.attrs.get(k) {
        None => Ok(d),
        Some(Attr::Int(v)) => Ok(*v),
        _ => Err(format!("{} has a malformed {k}", n.op)),
    };
    let float = |k: &str, d: f32| match n.attrs.get(k) {
        None => Ok(d),
        Some(Attr::Float(v)) => Ok(*v),
        _ => Err(format!("{} has a malformed {k}", n.op)),
    };
    let pair = |k: &str| -> Result<[usize; 2], String> {
        match n.attrs.get(k) {
            None => Ok([1, 1]),
            Some(Attr::Ints(v)) if v.len() == 2 && v.iter().all(|x| *x > 0) => Ok([v[0] as usize, v[1] as usize]),
            _ => Err(format!("{} has a {k} that is not two-dimensional", n.op)),
        }
    };
    Ok(match n.op.as_str() {
        "Identity" | "Add" | "Sub" | "Mul" | "Div" | "Pow" | "Relu" | "Sigmoid" | "Tanh" | "Sqrt" | "Log" | "Slice" | "Squeeze" | "Unsqueeze" | "MatMul" => {
            only(&[])?;
            match n.op.as_str() {
                "Identity" => Op::Unary(Unary::Identity),
                "Add" => Op::Binary(Binary::Add),
                "Sub" => Op::Binary(Binary::Sub),
                "Mul" => Op::Binary(Binary::Mul),
                "Div" => Op::Binary(Binary::Div),
                "Pow" => Op::Binary(Binary::Pow),
                "Relu" => Op::Unary(Unary::Relu),
                "Sigmoid" => Op::Unary(Unary::Sigmoid),
                "Tanh" => Op::Unary(Unary::Tanh),
                "Sqrt" => Op::Unary(Unary::Sqrt),
                "Log" => Op::Unary(Unary::Log),
                "Slice" => Op::Slice,
                "Squeeze" => Op::Squeeze,
                "Unsqueeze" => Op::Unsqueeze,
                _ => Op::MatMul,
            }
        }
        "Reshape" => {
            only(&["allowzero"])?;
            Op::Reshape { allow_zero: int("allowzero", 0)? != 0 }
        }
        "Transpose" => {
            only(&["perm"])?;
            match n.attrs.get("perm") {
                None => Op::Transpose(None),
                Some(Attr::Ints(p)) => Op::Transpose(Some(p.iter().map(|x| *x as usize).collect())),
                _ => return Err("Transpose has a malformed perm".into()),
            }
        }
        "Split" => {
            only(&["axis"])?;
            Op::Split { axis: int("axis", 0)?, outputs: n.outputs.len() }
        }
        "Concat" => {
            only(&["axis"])?;
            Op::Concat { axis: int("axis", i64::MIN)? }
        }
        "Flatten" => {
            only(&["axis"])?;
            Op::Flatten { axis: int("axis", 1)? }
        }
        "Gather" => {
            only(&["axis"])?;
            Op::Gather { axis: int("axis", 0)? }
        }
        "ReduceSum" => {
            only(&["keepdims", "noop_with_empty_axes"])?;
            Op::ReduceSum { keep: int("keepdims", 1)? != 0, noop_empty: int("noop_with_empty_axes", 0)? != 0 }
        }
        "Conv" => {
            only(&["dilations", "group", "kernel_shape", "pads", "strides", "auto_pad"])?;
            if let Some(a) = n.attrs.get("auto_pad") {
                if !matches!(a, Attr::Text(t) if t == "NOTSET") {
                    return Err("Conv with automatic padding".into());
                }
            }
            let pads = match n.attrs.get("pads") {
                None => [0; 4],
                Some(Attr::Ints(v)) if v.len() == 4 && v.iter().all(|x| *x >= 0) => {
                    [v[0] as usize, v[1] as usize, v[2] as usize, v[3] as usize]
                }
                _ => return Err("Conv with padding that is not two-dimensional".into()),
            };
            let group = int("group", 1)?;
            if group < 1 {
                return Err("Conv with no groups".into());
            }
            Op::Conv { group: group as usize, pads, strides: pair("strides")?, dilations: pair("dilations")? }
        }
        "Gemm" => {
            only(&["alpha", "beta", "transA", "transB"])?;
            Op::Gemm {
                alpha: float("alpha", 1.0)?,
                beta: float("beta", 1.0)?,
                trans_a: int("transA", 0)? != 0,
                trans_b: int("transB", 0)? != 0,
            }
        }
        "LayerNormalization" => {
            only(&["axis", "epsilon", "stash_type"])?;
            if n.outputs.iter().skip(1).any(|o| !o.is_empty()) {
                return Err("LayerNormalization with its statistics as outputs".into());
            }
            Op::LayerNorm { axis: int("axis", -1)?, epsilon: float("epsilon", 1e-5)? }
        }
        "GRU" => {
            only(&["direction", "hidden_size", "linear_before_reset", "layout"])?;
            if int("linear_before_reset", 0)? != 1 || int("layout", 0)? != 0 {
                return Err("a GRU other than linear-before-reset, sequence first".into());
            }
            let direction = match n.attrs.get("direction") {
                None => Direction::Forward,
                Some(Attr::Text(d)) if d == "forward" => Direction::Forward,
                Some(Attr::Text(d)) if d == "reverse" => Direction::Reverse,
                Some(Attr::Text(d)) if d == "bidirectional" => Direction::Both,
                _ => return Err("GRU with a malformed direction".into()),
            };
            let hidden = int("hidden_size", 0)?;
            if hidden <= 0 {
                return Err("GRU with no hidden size".into());
            }
            if n.inputs.get(4).is_some_and(|s| !s.is_empty()) {
                return Err("GRU with sequence lengths".into());
            }
            Op::Gru { hidden: hidden as usize, direction, transposed: false }
        }
        other => return Err(format!("no {other} operator")),
    })
}

fn axis(a: i64, rank: usize) -> Result<usize, String> {
    let r = rank as i64;
    let v = if a < 0 { a + r } else { a };
    if (0..r.max(1)).contains(&v) || (v == 0 && r == 0) {
        Ok(v as usize)
    } else {
        Err(format!("axis {a} for rank {rank}"))
    }
}

fn strides(shape: &[usize]) -> Vec<usize> {
    let mut s = vec![1; shape.len()];
    for i in (0..shape.len().saturating_sub(1)).rev() {
        s[i] = s[i + 1] * shape[i + 1];
    }
    s
}

/// Reads [src] in the order of an array of [shape] whose element at index i
/// is at start + sum(i_k * steps_k): a transpose or a slice, without copying
/// more than once.
fn walk(src: &[f32], shape: &[usize], start: isize, steps: &[isize]) -> Vec<f32> {
    let total: usize = shape.iter().product();
    let mut out = Vec::with_capacity(total);
    if total == 0 {
        return out;
    }
    if shape.is_empty() {
        out.push(src[start as usize]);
        return out;
    }
    let last = shape.len() - 1;
    let (n, step) = (shape[last], steps[last]);
    let mut idx = vec![0usize; shape.len()];
    let mut off = start;
    loop {
        if step == 1 {
            out.extend_from_slice(&src[off as usize..off as usize + n]);
        } else {
            out.extend((0..n).map(|k| src[(off + k as isize * step) as usize]));
        }
        let mut d = last;
        loop {
            if d == 0 {
                return out;
            }
            d -= 1;
            idx[d] += 1;
            off += steps[d];
            if idx[d] < shape[d] {
                break;
            }
            off -= steps[d] * shape[d] as isize;
            idx[d] = 0;
        }
    }
}

/// Each operator as its own closure, so the loops in [broadcast] and the
/// unary map are compiled per operator and vectorise, rather than calling
/// through a pointer for every element.
fn binary(a: &Tensor, b: &Tensor, op: Binary) -> Result<Tensor, String> {
    match op {
        Binary::Add => broadcast(a, b, |p, q| p + q),
        Binary::Sub => broadcast(a, b, |p, q| p - q),
        Binary::Mul => broadcast(a, b, |p, q| p * q),
        Binary::Div => broadcast(a, b, |p, q| p / q),
        Binary::Pow => broadcast(a, b, |p, q| if q == 2.0 { p * p } else { p.powf(q) }),
    }
}

fn unary(x: &Tensor, op: Unary) -> Tensor {
    let map = |f: fn(f32) -> f32| Tensor::new(x.shape.clone(), x.data.iter().map(|v| f(*v)).collect());
    match op {
        Unary::Identity => x.clone(),
        Unary::Relu => Tensor::new(x.shape.clone(), x.data.iter().map(|v| v.max(0.0)).collect()),
        Unary::Sigmoid => map(sigmoid),
        Unary::Tanh => map(f32::tanh),
        Unary::Sqrt => Tensor::new(x.shape.clone(), x.data.iter().map(|v| v.sqrt()).collect()),
        Unary::Log => map(f32::ln),
    }
}

fn broadcast(a: &Tensor, b: &Tensor, f: impl Fn(f32, f32) -> f32) -> Result<Tensor, String> {
    if a.shape == b.shape {
        return Ok(Tensor::new(a.shape.clone(), a.data.iter().zip(&b.data).map(|(x, y)| f(*x, *y)).collect()));
    }
    if b.data.len() == 1 && b.shape.len() <= a.shape.len() {
        let y = b.data[0];
        return Ok(Tensor::new(a.shape.clone(), a.data.iter().map(|x| f(*x, y)).collect()));
    }
    if a.data.len() == 1 && a.shape.len() <= b.shape.len() {
        let x = a.data[0];
        return Ok(Tensor::new(b.shape.clone(), b.data.iter().map(|y| f(x, *y)).collect()));
    }
    let rank = a.shape.len().max(b.shape.len());
    let pad = |s: &[usize]| [vec![1; rank - s.len()], s.to_vec()].concat();
    let (da, db) = (pad(&a.shape), pad(&b.shape));
    let mut shape = Vec::with_capacity(rank);
    for (x, y) in da.iter().zip(&db) {
        shape.push(match (x, y) {
            _ if x == y => *x,
            (_, 1) => *x,
            (1, _) => *y,
            _ => return Err(format!("{:?} and {:?} do not broadcast", a.shape, b.shape)),
        });
    }
    let steps = |d: &[usize]| -> Vec<isize> {
        let s = strides(d);
        d.iter().zip(s).map(|(n, s)| if *n == 1 { 0 } else { s as isize }).collect()
    };
    let (sa, sb) = (steps(&da), steps(&db));
    let total: usize = shape.iter().product();
    let mut out = Vec::with_capacity(total);
    if total == 0 {
        return Ok(Tensor::new(shape, out));
    }
    let last = rank - 1;
    let (n, ia, ib) = (shape[last], sa[last] as usize, sb[last] as usize);
    let mut idx = vec![0usize; rank];
    let (mut oa, mut ob) = (0isize, 0isize);
    loop {
        let (x, y) = (&a.data[oa as usize..], &b.data[ob as usize..]);
        match (ia, ib) {
            (1, 1) => out.extend(x[..n].iter().zip(&y[..n]).map(|(p, q)| f(*p, *q))),
            (1, 0) => out.extend(x[..n].iter().map(|p| f(*p, y[0]))),
            (0, 1) => out.extend(y[..n].iter().map(|q| f(x[0], *q))),
            _ => out.extend((0..n).map(|k| f(x[k * ia], y[k * ib]))),
        }
        let mut d = last;
        loop {
            if d == 0 {
                return Ok(Tensor::new(shape, out));
            }
            d -= 1;
            idx[d] += 1;
            oa += sa[d];
            ob += sb[d];
            if idx[d] < shape[d] {
                break;
            }
            oa -= sa[d] * shape[d] as isize;
            ob -= sb[d] * shape[d] as isize;
            idx[d] = 0;
        }
    }
}

fn walk_index(shape: &[usize], steps: &[isize]) -> Vec<usize> {
    let total: usize = shape.iter().product();
    let mut out = Vec::with_capacity(total);
    if total == 0 {
        return out;
    }
    let mut idx = vec![0usize; shape.len()];
    let mut off = 0isize;
    for _ in 0..total {
        out.push(off as usize);
        for d in (0..shape.len()).rev() {
            idx[d] += 1;
            off += steps[d];
            if idx[d] < shape[d] {
                break;
            }
            off -= steps[d] * shape[d] as isize;
            idx[d] = 0;
        }
    }
    out
}

/// out (m×n) += a (m×k) · b (k×n), all row-major. Written as a row of
/// multiply-adds per element of a, so the inner loop runs along the output
/// and vectorises without a horizontal sum.
///
/// Fused multiply-adds where the processor has them for certain: always on
/// 64-bit ARM, and on x86-64 when the CPU says so at run time.
fn matmul(a: &[f32], b: &[f32], m: usize, k: usize, n: usize, out: &mut [f32]) {
    #[cfg(target_arch = "x86_64")]
    if std::is_x86_feature_detected!("avx2") && std::is_x86_feature_detected!("fma") {
        // SAFETY: the features it is compiled for were just detected.
        return unsafe { matmul_fma(a, b, m, k, n, out) };
    }
    matmul_with::<{ cfg!(target_arch = "aarch64") }>(a, b, m, k, n, out)
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2,fma")]
unsafe fn matmul_fma(a: &[f32], b: &[f32], m: usize, k: usize, n: usize, out: &mut [f32]) {
    matmul_with::<true>(a, b, m, k, n, out)
}

#[inline(always)]
fn matmul_with<const FUSED: bool>(a: &[f32], b: &[f32], m: usize, k: usize, n: usize, out: &mut [f32]) {
    for i in 0..m {
        let row = &mut out[i * n..(i + 1) * n];
        for (p, av) in a[i * k..(i + 1) * k].iter().enumerate() {
            for (o, bv) in row.iter_mut().zip(&b[p * n..(p + 1) * n]) {
                *o = if FUSED { av.mul_add(*bv, *o) } else { *o + av * bv };
            }
        }
    }
}

/// Swaps the last two dimensions.
fn transpose_last2(t: &Tensor) -> Result<Tensor, String> {
    let r = t.shape.len();
    if r < 2 {
        return Err("a matrix with fewer than two dimensions".into());
    }
    let mut perm: Vec<usize> = (0..r).collect();
    perm.swap(r - 1, r - 2);
    Ok(permute(t, &perm))
}

fn permute(t: &Tensor, perm: &[usize]) -> Tensor {
    let s = strides(&t.shape);
    let shape: Vec<usize> = perm.iter().map(|p| t.shape[*p]).collect();
    let steps: Vec<isize> = perm.iter().map(|p| s[*p] as isize).collect();
    Tensor::new(shape.clone(), walk(&t.data, &shape, 0, &steps))
}

fn slice_axis(t: &Tensor, ax: usize, from: usize, len: usize) -> Tensor {
    let s = strides(&t.shape);
    let mut shape = t.shape.clone();
    shape[ax] = len;
    let steps: Vec<isize> = s.iter().map(|x| *x as isize).collect();
    Tensor::new(shape.clone(), walk(&t.data, &shape, (from * s[ax]) as isize, &steps))
}

fn arg<'v>(args: &[Option<&'v Value>], i: usize) -> Result<&'v Value, String> {
    args.get(i).copied().flatten().ok_or_else(|| format!("input {i} is missing"))
}

fn eval(op: &Op, args: &[Option<&Value>]) -> Result<Vec<Value>, String> {
    let x = || arg(args, 0)?.f();
    let one = |t: Tensor| Ok(vec![Value::F(t)]);
    match op {
        Op::Unary(op) => one(unary(x()?, *op)),
        Op::Binary(op) => one(binary(x()?, arg(args, 1)?.f()?, *op)?),
        Op::Reshape { allow_zero } => {
            let x = x()?;
            let want = arg(args, 1)?.ints()?;
            let mut shape = Vec::with_capacity(want.len());
            let mut infer = None;
            for (i, d) in want.iter().enumerate() {
                match *d {
                    -1 if infer.is_none() => {
                        infer = Some(i);
                        shape.push(1);
                    }
                    0 if !allow_zero => shape.push(*x.shape.get(i).ok_or("Reshape copies a missing dimension")?),
                    d if d >= 0 => shape.push(d as usize),
                    _ => return Err("Reshape to a malformed shape".into()),
                }
            }
            if let Some(i) = infer {
                let known: usize = shape.iter().product();
                if known == 0 || x.data.len() % known != 0 {
                    return Err("Reshape cannot infer a dimension".into());
                }
                shape[i] = x.data.len() / known;
            }
            if shape.iter().product::<usize>() != x.data.len() {
                return Err(format!("Reshape of {:?} to {:?}", x.shape, shape));
            }
            one(Tensor::new(shape, x.data.clone()))
        }
        Op::Transpose(perm) => {
            let x = x()?;
            let perm = perm.clone().unwrap_or_else(|| (0..x.shape.len()).rev().collect());
            let mut seen = perm.clone();
            seen.sort_unstable();
            if seen != (0..x.shape.len()).collect::<Vec<_>>() {
                return Err("Transpose with a malformed perm".into());
            }
            one(permute(x, &perm))
        }
        Op::Slice => {
            let x = x()?;
            let starts = arg(args, 1)?.ints()?;
            let ends = arg(args, 2)?.ints()?;
            let rank = x.shape.len();
            let axes: Vec<usize> = match args.get(3).copied().flatten() {
                Some(a) => a.ints()?.iter().map(|a| axis(*a, rank)).collect::<Result<_, _>>()?,
                None => (0..starts.len()).collect(),
            };
            let steps_in: Vec<i64> = match args.get(4).copied().flatten() {
                Some(s) => s.ints()?.to_vec(),
                None => vec![1; starts.len()],
            };
            if ends.len() != starts.len() || axes.len() != starts.len() || steps_in.len() != starts.len() {
                return Err("Slice with lists of different lengths".into());
            }
            let s = strides(&x.shape);
            let mut shape = x.shape.clone();
            let mut steps: Vec<isize> = s.iter().map(|v| *v as isize).collect();
            let mut start = 0isize;
            for i in 0..starts.len() {
                let (ax, step) = (axes[i], steps_in[i]);
                let d = x.shape[ax] as i64;
                let fix = |v: i64| if v < 0 { v.saturating_add(d) } else { v };
                let (b, e, len) = if step > 0 {
                    let (b, e) = (fix(starts[i]).clamp(0, d), fix(ends[i]).clamp(0, d));
                    (b, e, if e > b { (e - b + step - 1) / step } else { 0 })
                } else if step < 0 {
                    let (b, e) = (fix(starts[i]).clamp(0, d - 1), fix(ends[i]).clamp(-1, d - 1));
                    (b, e, if b > e { (b - e - step - 1) / -step } else { 0 })
                } else {
                    return Err("Slice with a zero step".into());
                };
                let _ = e;
                shape[ax] = len as usize;
                start += b as isize * s[ax] as isize;
                steps[ax] = step as isize * s[ax] as isize;
            }
            one(Tensor::new(shape.clone(), walk(&x.data, &shape, start, &steps)))
        }
        Op::Split { axis: a, outputs } => {
            let x = x()?;
            let ax = axis(*a, x.shape.len())?;
            let sizes: Vec<usize> = match args.get(1).copied().flatten() {
                Some(s) => s.ints()?.iter().map(|v| *v as usize).collect(),
                None => {
                    if x.shape[ax] % outputs != 0 {
                        return Err("Split into uneven parts".into());
                    }
                    vec![x.shape[ax] / outputs; *outputs]
                }
            };
            if sizes.len() != *outputs || sizes.iter().sum::<usize>() != x.shape[ax] {
                return Err("Split sizes that do not add up".into());
            }
            let mut from = 0;
            Ok(sizes
                .iter()
                .map(|len| {
                    let part = slice_axis(x, ax, from, *len);
                    from += len;
                    Value::F(part)
                })
                .collect())
        }
        Op::Squeeze => {
            let x = x()?;
            let rank = x.shape.len();
            let shape: Vec<usize> = match args.get(1).copied().flatten() {
                Some(a) => {
                    let axes: Vec<usize> = a.ints()?.iter().map(|a| axis(*a, rank)).collect::<Result<_, _>>()?;
                    if axes.iter().any(|a| x.shape[*a] != 1) {
                        return Err("Squeeze of a dimension that is not 1".into());
                    }
                    x.shape.iter().enumerate().filter(|(i, _)| !axes.contains(i)).map(|(_, d)| *d).collect()
                }
                None => x.shape.iter().copied().filter(|d| *d != 1).collect(),
            };
            one(Tensor::new(shape, x.data.clone()))
        }
        Op::Unsqueeze => {
            let x = x()?;
            let a = arg(args, 1)?.ints()?;
            let rank = x.shape.len() + a.len();
            let mut axes: Vec<usize> = a.iter().map(|v| axis(*v, rank)).collect::<Result<_, _>>()?;
            axes.sort_unstable();
            let mut dims = x.shape.iter();
            let shape: Vec<usize> =
                (0..rank).map(|i| if axes.contains(&i) { 1 } else { *dims.next().unwrap_or(&1) }).collect();
            one(Tensor::new(shape, x.data.clone()))
        }
        Op::Concat { axis: a } => {
            let parts: Vec<&Tensor> = args.iter().map(|v| v.ok_or("Concat input missing")?.f()).collect::<Result<_, String>>()?;
            let first = parts.first().ok_or("Concat of nothing")?;
            let ax = axis(*a, first.shape.len())?;
            let outer: usize = first.shape[..ax].iter().product();
            let mut shape = first.shape.clone();
            shape[ax] = 0;
            for p in &parts {
                if p.shape.len() != first.shape.len()
                    || p.shape.iter().enumerate().any(|(i, d)| i != ax && *d != first.shape[i])
                {
                    return Err(format!("Concat of {:?} and {:?}", first.shape, p.shape));
                }
                shape[ax] += p.shape[ax];
            }
            let mut out = Vec::with_capacity(shape.iter().product());
            for o in 0..outer {
                for p in &parts {
                    let inner = p.data.len() / outer.max(1);
                    out.extend_from_slice(&p.data[o * inner..(o + 1) * inner]);
                }
            }
            one(Tensor::new(shape, out))
        }
        Op::Flatten { axis: a } => {
            let x = x()?;
            let r = x.shape.len() as i64;
            let ax = if *a < 0 { a + r } else { *a };
            if !(0..=r).contains(&ax) {
                return Err("Flatten with a malformed axis".into());
            }
            let head: usize = x.shape[..ax as usize].iter().product();
            one(Tensor::new(vec![head, x.data.len() / head.max(1)], x.data.clone()))
        }
        Op::Gather { axis: a } => {
            let x = x()?;
            let ax = axis(*a, x.shape.len())?;
            let (ishape, idx) = match arg(args, 1)? {
                Value::I(s, v) => (s.clone(), v),
                Value::F(_) => return Err("Gather with float indices".into()),
            };
            let d = x.shape[ax];
            let outer: usize = x.shape[..ax].iter().product();
            let inner: usize = x.shape[ax + 1..].iter().product();
            let mut out = Vec::with_capacity(outer * idx.len() * inner);
            for o in 0..outer {
                for i in idx {
                    let j = if *i < 0 { *i + d as i64 } else { *i };
                    if !(0..d as i64).contains(&j) {
                        return Err("Gather index out of range".into());
                    }
                    let at = (o * d + j as usize) * inner;
                    out.extend_from_slice(&x.data[at..at + inner]);
                }
            }
            let shape = [&x.shape[..ax], &ishape[..], &x.shape[ax + 1..]].concat();
            one(Tensor::new(shape, out))
        }
        Op::ReduceSum { keep, noop_empty } => {
            let x = x()?;
            let rank = x.shape.len();
            let axes: Vec<usize> = match args.get(1).copied().flatten() {
                Some(a) if !a.ints()?.is_empty() => a.ints()?.iter().map(|v| axis(*v, rank)).collect::<Result<_, _>>()?,
                _ if *noop_empty => return one(x.clone()),
                _ => (0..rank).collect(),
            };
            let kept: Vec<usize> = x.shape.iter().enumerate().map(|(i, d)| if axes.contains(&i) { 1 } else { *d }).collect();
            let ks = strides(&kept);
            let steps: Vec<isize> = (0..rank).map(|i| if axes.contains(&i) { 0 } else { ks[i] as isize }).collect();
            let mut out = vec![0.0f32; kept.iter().product()];
            for (v, o) in x.data.iter().zip(walk_index(&x.shape, &steps)) {
                out[o] += v;
            }
            let shape = if *keep { kept } else { x.shape.iter().enumerate().filter(|(i, _)| !axes.contains(i)).map(|(_, d)| *d).collect() };
            one(Tensor::new(shape, out))
        }
        Op::Conv { group, pads, strides: st, dilations: dl } => {
            let x = x()?;
            let w = arg(args, 1)?.f()?;
            let bias = match args.get(2).copied().flatten() {
                Some(b) => Some(b.f()?),
                None => None,
            };
            if x.shape.len() != 4 || w.shape.len() != 4 {
                return Err("Conv that is not two-dimensional".into());
            }
            let (n, c, h, wd) = (x.shape[0], x.shape[1], x.shape[2], x.shape[3]);
            let (m, cg, kh, kw) = (w.shape[0], w.shape[1], w.shape[2], w.shape[3]);
            if c != cg * group || m % group != 0 || bias.is_some_and(|b| b.data.len() != m) {
                return Err("Conv with mismatched channels".into());
            }
            let span_h = dl[0] * (kh - 1) + 1;
            let span_w = dl[1] * (kw - 1) + 1;
            if h + pads[0] + pads[2] < span_h || wd + pads[1] + pads[3] < span_w {
                return Err("Conv kernel larger than its input".into());
            }
            let oh = (h + pads[0] + pads[2] - span_h) / st[0] + 1;
            let ow = (wd + pads[1] + pads[3] - span_w) / st[1] + 1;
            if kh == 1 && kw == 1 && *group == 1 && *st == [1, 1] && *pads == [0; 4] {
                let p = h * wd;
                let mut out = vec![0.0f32; n * m * p];
                for b in 0..n {
                    let o = &mut out[b * m * p..(b + 1) * m * p];
                    if let Some(bias) = bias {
                        for (mo, row) in o.chunks_exact_mut(p).enumerate() {
                            row.fill(bias.data[mo]);
                        }
                    }
                    matmul(&w.data, &x.data[b * c * p..(b + 1) * c * p], m, c, p, o);
                }
                return one(Tensor::new(vec![n, m, h, wd], out));
            }
            let mg = m / group;
            let columns: Vec<(usize, usize, isize)> = (0..kw)
                .map(|kx| {
                    let shift = (kx * dl[1]) as isize - pads[1] as isize;
                    let lo = (0..ow).find(|j| (j * st[1]) as isize + shift >= 0).unwrap_or(ow);
                    let hi = (0..ow).rev().find(|j| (j * st[1]) as isize + shift < wd as isize).map_or(0, |j| j + 1);
                    (lo, hi.max(lo), shift)
                })
                .collect();
            let mut out = vec![0.0f32; n * m * oh * ow];
            for b in 0..n {
                for mo in 0..m {
                    let g = mo / mg;
                    let o = &mut out[(b * m + mo) * oh * ow..(b * m + mo + 1) * oh * ow];
                    if let Some(bias) = bias {
                        o.fill(bias.data[mo]);
                    }
                    for ci in 0..cg {
                        let ch = g * cg + ci;
                        let plane = &x.data[(b * c + ch) * h * wd..(b * c + ch + 1) * h * wd];
                        for ky in 0..kh {
                            for (kx, &(lo, hi, shift_x)) in columns.iter().enumerate() {
                                let wv = w.data[((mo * cg + ci) * kh + ky) * kw + kx];
                                for y in 0..oh {
                                    let iy = (y * st[0] + ky * dl[0]) as isize - pads[0] as isize;
                                    if iy < 0 || iy >= h as isize {
                                        continue;
                                    }
                                    let row = &plane[iy as usize * wd..(iy as usize + 1) * wd];
                                    let orow = &mut o[y * ow..(y + 1) * ow];
                                    for j in lo..hi {
                                        orow[j] += wv * row[((j * st[1]) as isize + shift_x) as usize];
                                    }
                                }
                            }
                        }
                    }
                }
            }
            one(Tensor::new(vec![n, m, oh, ow], out))
        }
        Op::Gemm { alpha, beta, trans_a, trans_b } => {
            let a = x()?;
            let b = arg(args, 1)?.f()?;
            if a.shape.len() != 2 || b.shape.len() != 2 {
                return Err("Gemm of something other than matrices".into());
            }
            let (at, bt);
            let a = if *trans_a {
                at = transpose_last2(a)?;
                &at
            } else {
                a
            };
            let b = if *trans_b {
                bt = transpose_last2(b)?;
                &bt
            } else {
                b
            };
            let (m, k, nn) = (a.shape[0], a.shape[1], b.shape[1]);
            if b.shape[0] != k {
                return Err("Gemm with mismatched sizes".into());
            }
            let mut out = vec![0.0f32; m * nn];
            matmul(&a.data, &b.data, m, k, nn, &mut out);
            if *alpha != 1.0 {
                out.iter_mut().for_each(|v| *v *= alpha);
            }
            let mut y = Tensor::new(vec![m, nn], out);
            if let Some(c) = args.get(2).copied().flatten() {
                let c = c.f()?;
                let beta = *beta;
                let scaled = Tensor::new(c.shape.clone(), c.data.iter().map(|v| v * beta).collect());
                y = broadcast(&y, &scaled, |p, q| p + q)?;
                if y.shape != [m, nn] {
                    return Err("Gemm with a bias larger than its output".into());
                }
            }
            one(y)
        }
        Op::MatMul => {
            let a = x()?;
            let b = arg(args, 1)?.f()?;
            let (ra, rb) = (a.shape.len(), b.shape.len());
            if ra < 2 || rb < 2 {
                return Err("MatMul of a vector".into());
            }
            let (m, k, nn) = (a.shape[ra - 2], a.shape[ra - 1], b.shape[rb - 1]);
            if b.shape[rb - 2] != k {
                return Err(format!("MatMul of {:?} and {:?}", a.shape, b.shape));
            }
            let index = |s: &[usize]| Tensor::new(s.to_vec(), (0..s.iter().product::<usize>()).map(|i| i as f32).collect());
            let (mut shape, pairs) = broadcast_pairs(&index(&a.shape[..ra - 2]), &index(&b.shape[..rb - 2]))?;
            let mut out = vec![0.0f32; pairs.len() * m * nn];
            for (q, (ia, ib)) in pairs.into_iter().enumerate() {
                matmul(
                    &a.data[ia * m * k..(ia + 1) * m * k],
                    &b.data[ib * k * nn..(ib + 1) * k * nn],
                    m,
                    k,
                    nn,
                    &mut out[q * m * nn..(q + 1) * m * nn],
                );
            }
            shape.extend_from_slice(&[m, nn]);
            one(Tensor::new(shape, out))
        }
        Op::LayerNorm { axis: a, epsilon } => {
            let x = x()?;
            let ax = axis(*a, x.shape.len())?;
            let inner: usize = x.shape[ax..].iter().product();
            let scale = arg(args, 1)?.f()?;
            let bias = match args.get(2).copied().flatten() {
                Some(b) => Some(b.f()?),
                None => None,
            };
            if scale.data.len() != inner || bias.is_some_and(|b| b.data.len() != inner) {
                return Err("LayerNormalization with a scale of the wrong size".into());
            }
            let mut out = Vec::with_capacity(x.data.len());
            for row in x.data.chunks_exact(inner) {
                let mean = row.iter().sum::<f32>() / inner as f32;
                let var = row.iter().map(|v| (v - mean) * (v - mean)).sum::<f32>() / inner as f32;
                let inv = 1.0 / (var + epsilon).sqrt();
                for (i, v) in row.iter().enumerate() {
                    let y = (v - mean) * inv * scale.data[i];
                    out.push(match bias {
                        Some(b) => y + b.data[i],
                        None => y,
                    });
                }
            }
            one(Tensor::new(x.shape.clone(), out))
        }
        Op::Gru { hidden: h, direction, transposed } => {
            let x = x()?;
            let (wo, ro);
            let (w, r) = if *transposed {
                (arg(args, 1)?.f()?, arg(args, 2)?.f()?)
            } else {
                wo = transpose_last2(arg(args, 1)?.f()?)?;
                ro = transpose_last2(arg(args, 2)?.f()?)?;
                (&wo, &ro)
            };
            let dirs = if *direction == Direction::Both { 2 } else { 1 };
            if x.shape.len() != 3 || w.shape != [dirs, x.shape[2], 3 * h] || r.shape != [dirs, *h, 3 * h] {
                return Err("GRU with mismatched weights".into());
            }
            let (seq, batch, inp) = (x.shape[0], x.shape[1], x.shape[2]);
            let bias = match args.get(3).copied().flatten() {
                Some(b) if b.f()?.shape == [dirs, 6 * h] => Some(b.f()?),
                Some(_) => return Err("GRU with a bias of the wrong size".into()),
                None => None,
            };
            let start = match args.get(5).copied().flatten() {
                Some(s) if s.f()?.shape == [dirs, batch, *h] => Some(s.f()?),
                Some(_) => return Err("GRU with a start state of the wrong size".into()),
                None => None,
            };
            let mut y = vec![0.0f32; seq * dirs * batch * h];
            let mut yh = vec![0.0f32; dirs * batch * h];
            let mut gx = vec![0.0f32; seq * 3 * h];
            let mut gh = vec![0.0f32; 3 * h];
            for d in 0..dirs {
                let reverse = *direction == Direction::Reverse || d == 1;
                let wd = &w.data[d * inp * 3 * h..(d + 1) * inp * 3 * h];
                let rd = &r.data[d * h * 3 * h..(d + 1) * h * 3 * h];
                let (wb, rb) = match bias {
                    Some(bs) => (&bs.data[d * 6 * h..d * 6 * h + 3 * h], &bs.data[d * 6 * h + 3 * h..(d + 1) * 6 * h]),
                    None => (&[][..], &[][..]),
                };
                for b in 0..batch {
                    for t in 0..seq {
                        let row = &mut gx[t * 3 * h..(t + 1) * 3 * h];
                        if wb.is_empty() {
                            row.fill(0.0);
                        } else {
                            row.copy_from_slice(wb);
                        }
                        matmul(&x.data[(t * batch + b) * inp..(t * batch + b + 1) * inp], wd, 1, inp, 3 * h, row);
                    }
                    let mut state = match start {
                        Some(s) => s.data[(d * batch + b) * h..(d * batch + b + 1) * h].to_vec(),
                        None => vec![0.0; *h],
                    };
                    for step in 0..seq {
                        let t = if reverse { seq - 1 - step } else { step };
                        let gx = &gx[t * 3 * h..(t + 1) * 3 * h];
                        if rb.is_empty() {
                            gh.fill(0.0);
                        } else {
                            gh.copy_from_slice(rb);
                        }
                        matmul(&state, rd, 1, *h, 3 * h, &mut gh);
                        for k in 0..*h {
                            let z = sigmoid(gx[k] + gh[k]);
                            let reset = sigmoid(gx[h + k] + gh[h + k]);
                            let cand = (gx[2 * h + k] + reset * gh[2 * h + k]).tanh();
                            state[k] = (1.0 - z) * cand + z * state[k];
                        }
                        y[((t * dirs + d) * batch + b) * h..((t * dirs + d) * batch + b + 1) * h].copy_from_slice(&state);
                    }
                    yh[(d * batch + b) * h..(d * batch + b + 1) * h].copy_from_slice(&state);
                }
            }
            Ok(vec![
                Value::F(Tensor::new(vec![seq, dirs, batch, *h], y)),
                Value::F(Tensor::new(vec![dirs, batch, *h], yh)),
            ])
        }
    }
}

/// The broadcast batch shape of two stacks of matrices, and for each matrix of
/// the result, which matrix of each stack it multiplies.
fn broadcast_pairs(a: &Tensor, b: &Tensor) -> Result<(Vec<usize>, Vec<(usize, usize)>), String> {
    let ia = broadcast(a, &Tensor::new(b.shape.clone(), vec![0.0; b.data.len()]), |p, _| p)?;
    let ib = broadcast(&Tensor::new(a.shape.clone(), vec![0.0; a.data.len()]), b, |_, q| q)?;
    let pairs = ia.data.iter().zip(&ib.data).map(|(p, q)| (*p as usize, *q as usize)).collect();
    Ok((ia.shape, pairs))
}

// ---- The graph.

struct Node {
    op: Op,
    inputs: Vec<Option<usize>>,
    outputs: Vec<Option<usize>>,
}

pub struct Engine {
    slots: usize,
    consts: Vec<Option<Value>>,
    nodes: Vec<Node>,
    inputs: Vec<usize>,
    outputs: Vec<usize>,
}

impl Engine {
    /// Reads an ONNX model with the given input and output names. Returns the
    /// engine and the model's metadata.
    pub fn load(bytes: &[u8], inputs: &[&str], outputs: &[&str]) -> Result<(Self, HashMap<String, String>), String> {
        let mut meta = HashMap::new();
        let mut graph: &[u8] = &[];
        let mut r = Reader::new(bytes);
        while let Some((n, field)) = r.next()? {
            match (n, field) {
                (7, Field::Bytes(g)) => graph = g,
                (14, Field::Bytes(e)) => {
                    let (mut k, mut v) = (String::new(), String::new());
                    let mut er = Reader::new(e);
                    while let Some((n, f)) = er.next()? {
                        match n {
                            1 => k = text(f)?,
                            2 => v = text(f)?,
                            _ => {}
                        }
                    }
                    meta.insert(k, v);
                }
                _ => {}
            }
        }
        if graph.is_empty() {
            return Err("not an ONNX model".into());
        }
        let (mut raw_nodes, mut inits, mut ins, mut outs) = (vec![], vec![], vec![], vec![]);
        let mut r = Reader::new(graph);
        while let Some((n, field)) = r.next()? {
            if let Field::Bytes(b) = field {
                match n {
                    1 => raw_nodes.push(parse_node(b)?),
                    5 => inits.push(parse_tensor(b)?),
                    11 => ins.push(value_name(b)?),
                    12 => outs.push(value_name(b)?),
                    _ => {}
                }
            }
        }
        let mut names: HashMap<String, usize> = HashMap::new();
        fn slot(names: &mut HashMap<String, usize>, name: &str) -> usize {
            let next = names.len();
            *names.entry(name.to_string()).or_insert(next)
        }
        let mut consts: Vec<Option<Value>> = Vec::new();
        for (name, value) in inits {
            let s = slot(&mut names, &name);
            consts.resize(consts.len().max(s + 1), None);
            consts[s] = Some(value);
        }
        ins.retain(|i| !names.contains_key(i));
        if ins != inputs || outs != outputs {
            return Err(format!("a model with inputs {ins:?} and outputs {outs:?}"));
        }
        let input_slots: Vec<usize> = ins.iter().map(|i| slot(&mut names, i)).collect();
        let mut nodes = Vec::with_capacity(raw_nodes.len());
        for n in &raw_nodes {
            let op = build_op(n)?;
            let mut opt = |s: &String| if s.is_empty() { None } else { Some(slot(&mut names, s)) };
            let inputs = n.inputs.iter().map(&mut opt).collect();
            let outputs = n.outputs.iter().map(&mut opt).collect();
            nodes.push(Node { op, inputs, outputs });
        }
        let output_slots: Vec<usize> = outs.iter().map(|o| slot(&mut names, o)).collect();
        let slots = names.len();
        consts.resize(slots, None);

        // Everything that depends only on the weights is worked out now.
        let mut live = Vec::with_capacity(nodes.len());
        for mut node in nodes {
            if node.inputs.iter().flatten().all(|i| consts[*i].is_some()) {
                let args: Vec<Option<&Value>> = node.inputs.iter().map(|i| i.and_then(|i| consts[i].as_ref())).collect();
                let values = eval(&node.op, &args).map_err(|e| format!("folding: {e}"))?;
                for (o, v) in node.outputs.iter().zip(values) {
                    if let Some(o) = o {
                        consts[*o] = Some(v);
                    }
                }
                continue;
            }
            // Weights turned once, so the loops in matmul run along the output.
            fn turn(consts: &mut Vec<Option<Value>>, node: &mut Node, at: usize) -> Result<bool, String> {
                let Some(Some(i)) = node.inputs.get(at).copied() else { return Ok(false) };
                let Some(w) = consts[i].as_ref() else { return Ok(false) };
                let turned = transpose_last2(w.f()?)?;
                consts.push(Some(Value::F(turned)));
                node.inputs[at] = Some(consts.len() - 1);
                Ok(true)
            }
            match node.op {
                Op::Gemm { trans_b: true, .. } => {
                    if turn(&mut consts, &mut node, 1)? {
                        if let Op::Gemm { trans_b, .. } = &mut node.op {
                            *trans_b = false;
                        }
                    }
                }
                Op::Gru { transposed: false, .. } => {
                    let both = node.inputs.len() >= 3 && node.inputs[1..3].iter().all(|i| i.is_some_and(|i| consts[i].is_some()));
                    if both && turn(&mut consts, &mut node, 1)? && turn(&mut consts, &mut node, 2)? {
                        if let Op::Gru { transposed, .. } = &mut node.op {
                            *transposed = true;
                        }
                    }
                }
                _ => {}
            }
            live.push(node);
        }
        let slots = consts.len();
        Ok((Self { slots, consts, nodes: live, inputs: input_slots, outputs: output_slots }, meta))
    }

    pub fn run(&self, inputs: Vec<Tensor>) -> Result<Vec<Tensor>, String> {
        let mut vals: Vec<Option<Value>> = vec![None; self.slots];
        for (s, t) in self.inputs.iter().zip(inputs) {
            vals[*s] = Some(Value::F(t));
        }
        for node in &self.nodes {
            let values = {
                let args: Vec<Option<&Value>> = node
                    .inputs
                    .iter()
                    .map(|i| i.and_then(|i| self.consts[i].as_ref().or(vals[i].as_ref())))
                    .collect();
                eval(&node.op, &args)?
            };
            for (o, v) in node.outputs.iter().zip(values) {
                if let Some(o) = o {
                    vals[*o] = Some(v);
                }
            }
        }
        self.outputs
            .iter()
            .map(|o| match vals[*o].take().or_else(|| self.consts[*o].clone()) {
                Some(Value::F(t)) => Ok(t),
                _ => Err("an output was never computed".into()),
            })
            .collect()
    }
}
