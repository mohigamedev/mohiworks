//! Switches that make translated shaders exact to the console's float rules
//! where the host differs, at a cost in GPU time. Both are off by default.

/// `VICTORY_F16_NEAREST=1`: the results of 16-bit float operations (`v_add_f16`,
/// `v_mul_f16`, `v_cvt_f16_f32` ...) are rounded to nearest as the console rounds them
/// (`Lower::f16_nearest`) instead of as the host's `f32tof16` does (toward zero on NVIDIA:
/// the last place of a result that is not exact is then one lower than the console's).
/// Off by default: it is exact but untried in a game run, and adds instructions to every
/// such operation. The wave sum of 16-bit floats (`Lower::half_sum`) is always exact.
pub(super) fn f16_nearest_on() -> bool {
    #[cfg(test)]
    if let Some(on) = TEST_F16_NEAREST.get() {
        return on;
    }
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("VICTORY_F16_NEAREST").is_some_and(|v| v == "1"))
}

#[cfg(test)]
thread_local! {
    /// A test's choice for [`f16_nearest_on`], for its thread only.
    pub(super) static TEST_F16_NEAREST: std::cell::Cell<Option<bool>> = const { std::cell::Cell::new(None) };
    /// A test's choice for [`exact_floats_on`], for its thread only.
    pub(super) static TEST_EXACT_FLOATS: std::cell::Cell<Option<bool>> = const { std::cell::Cell::new(None) };
}

/// `VICTORY_EXACT_FLOATS=1`: 32-bit denormal operands read as zeros on the bits, as the
/// console's float mode reads them, before maximums, minimums, medians, conversions and
/// output modifiers. Off by default (the host's own denormal mode decides): it adds about a
/// dozen instructions to every maximum and minimum; with it always on, a gameplay frame
/// took about four times the GPU time (2026-11-25, Series S route). -0 ordered below +0
/// in maximums and minimums is kept either way.
pub(super) fn exact_floats_on() -> bool {
    #[cfg(test)]
    if let Some(on) = TEST_EXACT_FLOATS.get() {
        return on;
    }
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("VICTORY_EXACT_FLOATS").is_some_and(|v| v == "1"))
}
