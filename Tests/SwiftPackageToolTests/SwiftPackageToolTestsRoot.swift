import Testing

/// the serialization root for this test target.
///
/// swift testing runs top-level suites in parallel with one another, and the
/// `.serialized` trait orders only a suite's own tests and its descendants. every
/// suite in this target therefore nests under this root, so the whole target
/// runs one test at a time. that is the discipline that lets
/// ``Subprocess/capture`` launch without a serializing gate of its own: no two
/// spawns are ever in flight at once.
@Suite("SwiftPackageToolTests", .serialized)
struct SwiftPackageToolTestsRoot {}
