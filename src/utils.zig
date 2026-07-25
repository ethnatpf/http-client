/// Hard-coded for 3 digits max. Could be improved but works for our use case.
pub fn decimalLength(value: u8) usize {
    if (value < 10) return 1;
    if (value < 100) return 2;
    return 3;
}
