<!-- read as: markdown -->
Yes. In fact, the asymptotic supremum is exactly $1+o(1)$. The upper bound follows from a random divisibility-chain argument; the quoted examples with $\Omega(n)=k$ show the constant $1$ is sharp.

Let $\Omega(n)$ denote the number of prime factors of $n$, counted with multiplicity, and write $p^\alpha\Vert n$ when $p^\alpha\mid n$ but $p^{\alpha+1}\nmid n$.

## The random chain

For every prime $p$, let $Y_p$ be independent with exponential tail

$$
\mathbb P(Y_p\ge t)=p^{-t}\qquad(t\ge 0).
$$

Equivalently, $Y_p$ is exponential with rate $\log p$. For $t>1$, define

$$
N(t):=\prod_p p^{\lfloor Y_p/t\rfloor}.
$$

This is almost surely a finite integer for every $t>1$, because

$$
\sum_p \mathbb P(Y_p\ge t)=\sum_p p^{-t}<\infty.
$$

Also, if $t_1>t_2>1$, then

$$
\lfloor Y_p/t_1\rfloor\le \lfloor Y_p/t_2\rfloor
$$

for every prime $p$, so

$$
N(t_1)\mid N(t_2).
$$

Thus, as $t$ decreases from $\infty$ to $1$, the values $N(t)$ form a random divisibility chain.

For an integer $n\ge 2$, define

$$
H_n:=\{\exists\,t>1:N(t)=n\},
$$

and let

$$
h(n):=\mathbb P(H_n).
$$

If $A$ is primitive, then the events $\{H_a:a\in A\}$ are pairwise disjoint: if a single chain hits both $a$ and $b$, then one of $a,b$ divides the other. Hence, for every primitive set $A$,

$$
\sum_{a\in A} h(a)\le 1.
$$

So it remains to show that, uniformly for large $n$,

$$
h(n)\ge (1-o(1))\frac1{n\log n}.
$$

## Exact hitting probability

Let

$$
n=\prod_{p^\alpha\Vert n}p^\alpha.
$$

The chain hits $n$ when, for some $t>1$, the required prime-power thresholds have appeared but no forbidden threshold has appeared. A direct calculation gives

$$
h(n)
=
\int_1^\infty
\frac{n^{-t}}{\zeta(t)}
\left(
\sum_{p^\alpha\Vert n}\frac{\alpha\log p}{1-p^{-t}}
\right)\,dt.
$$

Here is the derivation. Suppose the last required threshold is the $\alpha$-th threshold of a prime $p^\alpha\Vert n$, occurring at parameter $t$. Then $Y_p=\alpha t$, with density

$$
\alpha\log p\cdot p^{-\alpha t}\,dt.
$$

For every other $q^\beta\Vert n$, we need

$$
\beta t<Y_q<(\beta+1)t,
$$

which has probability

$$
q^{-\beta t}(1-q^{-t}).
$$

For every prime $r\nmid n$, we need $Y_r<t$, which has probability $1-r^{-t}$. Multiplying and summing over the possible final primes gives

$$
\begin{aligned}
h(n)
&=
\sum_{p^\alpha\Vert n}
\int_1^\infty
\alpha\log p\cdot p^{-\alpha t}
\prod_{\substack{q^\beta\Vert n\\q\ne p}}
q^{-\beta t}(1-q^{-t})
\prod_{r\nmid n}(1-r^{-t})\,dt \\
&=
\int_1^\infty
\frac{n^{-t}}{\zeta(t)}
\left(
\sum_{p^\alpha\Vert n}\frac{\alpha\log p}{1-p^{-t}}
\right)\,dt.
\end{aligned}
$$

Now observe that for $t>1$,

$$
\sum_{p^\alpha\Vert n}\frac{\alpha\log p}{1-p^{-t}}
\ge
\sum_{p^\alpha\Vert n}\alpha\log p
=
\log n.
$$

Therefore

$$
h(n)
\ge
(\log n)\int_1^\infty \frac{n^{-t}}{\zeta(t)}\,dt.
$$

Let $L=\log n$. Restricting the integral to $1<t<1+\delta$, with $\delta>0$, and writing $t=1+\sigma$, we get

$$
h(n)
\ge
L n^{-1}\int_0^\delta \frac{e^{-L\sigma}}{\zeta(1+\sigma)}\,d\sigma.
$$

Since

$$
\zeta(1+\sigma)=\frac1\sigma+O(1)
\qquad(\sigma\downarrow 0),
$$

we have, uniformly for $0<\sigma\le\delta$,

$$
\frac1{\zeta(1+\sigma)}\ge (1-\eta(\delta))\sigma,
$$

where $\eta(\delta)\to 0$ as $\delta\to 0$. Hence

$$
\begin{aligned}
h(n)
&\ge
(1-\eta(\delta))L n^{-1}
\int_0^\delta e^{-L\sigma}\sigma\,d\sigma \\
&=
(1-\eta(\delta))\frac1{nL}
\left(1-e^{-\delta L}(1+\delta L)\right).
\end{aligned}
$$

Choose, for example,

$$
\delta=\delta_x:=(\log x)^{-1/2}.
$$

Then for every $n\ge x$, $L=\log n\ge \log x$, so

$$
e^{-\delta_x L}(1+\delta_x L)
\le
e^{-\sqrt{\log x}}\bigl(1+\sqrt{\log x}\bigr)
=o(1),
$$

and also $\eta(\delta_x)=o(1)$. Thus, uniformly for all $n\ge x$,

$$
h(n)\ge (1-o(1))\frac1{n\log n}.
$$

## Applying the chain to a primitive set

Let $A\subset[x,\infty)$ be primitive. For every finite $B\subset A$, the disjointness of the hitting events gives

$$
\sum_{b\in B}h(b)\le 1.
$$

Using the uniform lower bound for $h(b)$, we obtain

$$
(1-o(1))\sum_{b\in B}\frac1{b\log b}
\le
\sum_{b\in B}h(b)
\le 1.
$$

Therefore

$$
\sum_{b\in B}\frac1{b\log b}\le 1+o(1),
$$

with the $o(1)$ depending only on $x$, not on $B$ or $A$. Taking the supremum over finite $B\subset A$ gives

$$
\sum_{a\in A}\frac1{a\log a}\le 1+o(1).
$$

So the proposed assertion is true.

Moreover, the constant $1$ is best possible: for $A_k=\{n:\Omega(n)=k\}$, one has $A_k\subset[2^k,\infty)$, $A_k$ is primitive, and your quoted asymptotic gives

$$
\sum_{\Omega(n)=k}\frac1{n\log n}
=
1-(c+o(1))k^2 2^{-k}.
$$

Thus the asymptotic upper bound $1+o(1)$ cannot be replaced by anything below $1$.
