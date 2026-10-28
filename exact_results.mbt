///|
/// ARC targets can reuse an unaliased backing buffer while constructing a new
/// result array. The pool retains at most the most recent exact result.
#cfg(any(target="native", target="wasm"))
priv struct ExactResults {
  mut cached : Array[Suggestion]?
}

///|
#cfg(any(target="native", target="wasm"))
fn ExactResults::new() -> ExactResults {
  { cached: None, }
}

///|
#cfg(any(target="native", target="wasm"))
fn ExactResults::single(
  self : ExactResults,
  suggestion : Suggestion,
) -> Array[Suggestion] {
  let previous = self.cached
  self.cached = None
  let result = match previous {
    Some(previous) => renew_exact_result(previous, suggestion)
    None => [suggestion]
  }
  self.cached = Some(result)
  result
}

///|
/// Consume the old array before converting its view. The core conversion can
/// reuse the buffer only if no surviving array, view, or iterator owns it;
/// otherwise it copies. This preserves the public result's mutable semantics.
#cfg(any(target="native", target="wasm"))
#owned(previous)
fn renew_exact_result(
  previous : Array[Suggestion],
  suggestion : Suggestion,
) -> Array[Suggestion] {
  if previous.length() != 1 {
    return [suggestion]
  }
  let result = previous[:].to_owned()
  result[0] = suggestion
  result
}

///|
#cfg(not(any(target="native", target="wasm")))
priv enum ExactResults {
  Fresh
}

///|
#cfg(not(any(target="native", target="wasm")))
fn ExactResults::new() -> ExactResults {
  Fresh
}

///|
#cfg(not(any(target="native", target="wasm")))
fn ExactResults::single(
  _self : ExactResults,
  suggestion : Suggestion,
) -> Array[Suggestion] {
  [suggestion]
}
