<!-- read as: html -->
This is a tracking issue for generic associated types ([rust-lang/rfcs#1598](https://github.com/rust-lang/rfcs/pull/1598))

# Repository

- Detailed tracking information is available at the [GAT initiative repository](https://rust-lang.github.io/generic-associated-types-initiative/)

# Unresolved questions:

- [x] [GATs: Decide whether to have defaults for `where Self: 'a` #87479](https://github.com/rust-lang/rust/issues/87479) -- defaults for `where Self: 'a`
- [x] [Proposal: Change syntax of where clauses on type aliases #89122](https://github.com/rust-lang/rust/issues/89122) -- where to put where clauses

# Blocking bugs

See also the [`GATs-blocking` tag](https://github.com/rust-lang/rust/issues?q=is%3Aopen+is%3Aissue+label%3AGATs-blocking) (the list below *should* be a superset of that, but its good to double-check).

- [x] [lifetime-parametric GATs cause ICEs (with feature(generic_associated_types)) #62521](https://github.com/rust-lang/rust/issues/62521)
- [ ] [~~Associated type projections don't play well with HRTBs and normalization #30472~~](https://github.com/rust-lang/rust/issues/30472) No longer blocking
- [x] [Pretty printing loses associated type generics and where clauses #67509](https://github.com/rust-lang/rust/issues/67509)
- [x] [Allow generic associate types in trait paths #67510](https://github.com/rust-lang/rust/issues/67510)
- [x] [Generic associated types can shadow lifetimes #67512](https://github.com/rust-lang/rust/issues/67512)
- [x] [Implement type- and const-generic associated types #67513](https://github.com/rust-lang/rust/issues/67513)
- [x] [GAT's arent typechecked, and can cause UB #68641](https://github.com/rust-lang/rust/issues/68641)
- [x] [GAT's and broken LLVM #68642](https://github.com/rust-lang/rust/issues/68642)
- [x] [GAT ICE: use of PlaceRef { local: \_0, projection: [\] } before def #68643](https://github.com/rust-lang/rust/issues/68643)
- [x] [GAT ICE: Encountered error `Unimplemented` selecting \`Binder #68644](https://github.com/rust-lang/rust/issues/68644)
- [x] [GAT ICE: FulfillmentError #68645](https://github.com/rust-lang/rust/issues/68645)
- [x] [GAT ICE: impl item and trait item have different parameter counts #68648](https://github.com/rust-lang/rust/issues/68648)
- [x] [GAT ICE: place local already assigned to #68649](https://github.com/rust-lang/rust/issues/68649)
- [x] [GAT ICE: unsize_thin_ptr: called on bad types #68650](https://github.com/rust-lang/rust/issues/68650)
- [x] [GAT ICE: codegen_argument #68652](https://github.com/rust-lang/rust/issues/68652)
- [x] [GAT ICE: unelided lifetime in signature #68653](https://github.com/rust-lang/rust/issues/68653)
- [x] [GAT ICE: cannot directly store unsized values #68656](https://github.com/rust-lang/rust/issues/68656)
- [x] [Broken LLVM with GAT #74684](https://github.com/rust-lang/rust/issues/74684)
- [x] [[nightly\] ICE when using GATs with const generics #75415](https://github.com/rust-lang/rust/issues/75415)
- [x] [ICE when combining GATs and HRTBs #76826](https://github.com/rust-lang/rust/issues/76826)
- [x] [Internal Compiler Error caused by Generic Associated Types #79768](https://github.com/rust-lang/rust/issues/79768)
- [ ] [~~Enum variant with GAT field fails to derive Sized #80626~~](https://github.com/rust-lang/rust/issues/80626) Not GATs specific, not blocking
- [x] [Error when inferring a lifetime in return type using GATs #81487](https://github.com/rust-lang/rust/issues/81487)
- [x] [Bad diagnostics for GATs in trait paths #81801](https://github.com/rust-lang/rust/issues/81801)
- [x] [defaults on `GATs` emit an error but function correctlyish #99205](https://github.com/rust-lang/rust/issues/99205)

# Postponed work

- [ ] [Trait objects do not work with generic associated types #81823](https://github.com/rust-lang/rust/issues/81823)
