// Port of generic algorithms from sqlglot/helper.py (tsort, merge_ranges).

///|
/// Python `helper.tsort`: sorts a directed acyclic graph (node -> dependencies) in
/// topological order; nodes that become ready at the same time are sorted. Raises
/// `ValueError("Cycle error")` when the graph has a cycle.
pub fn[T : Hash + Eq + Compare] tsort(
  dag : Map[T, Array[T]],
) -> Array[T] raise SqlglotError {
  let graph : Map[T, Array[T]] = Map([])
  for node, deps in dag {
    graph[node] = deps.copy()
  }
  for _, deps in dag {
    for dep in deps {
      if !graph.contains(dep) {
        graph[dep] = []
      }
    }
  }
  let result = []
  while !graph.is_empty() {
    let current = []
    for node, deps in graph {
      if deps.is_empty() {
        current.push(node)
      }
    }
    if current.is_empty() {
      raise ValueError("Cycle error")
    }
    for node in current {
      graph.remove(node)
    }
    for node, deps in graph {
      graph[node] = deps.filter(d => !current.contains(d))
    }
    current.sort()
    result.append(current)
  }
  result
}

///|
/// Python `helper.merge_ranges`: merges a sequence of `(low, high)` ranges whose values
/// belong to some totally-ordered set.
pub fn[T : Compare] merge_ranges(ranges : Array[(T, T)]) -> Array[(T, T)] {
  if ranges.is_empty() {
    return []
  }
  let sorted = ranges.copy()
  sorted.sort()
  let merged = [sorted[0]]
  for i in 1..<sorted.length() {
    let (start, end) = sorted[i]
    let (last_start, last_end) = merged[merged.length() - 1]
    if start <= last_end {
      merged[merged.length() - 1] = (
        last_start,
        if last_end >= end {
          last_end
        } else {
          end
        },
      )
    } else {
      merged.push((start, end))
    }
  }
  merged
}
