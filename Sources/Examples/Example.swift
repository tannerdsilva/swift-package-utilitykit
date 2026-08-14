public enum Example {
	/// returns the larger of two comparable values.
	public static func max<T: Comparable>(_ a: T, _ b: T) -> T {
		a > b ? a : b
	}
}
