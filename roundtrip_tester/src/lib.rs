use borsh::{BorshSerialize, BorshDeserialize};

// Each `id` corresponds to a specific test case, this function is supposed to import the given object, create a new object based on the `id` it receives, assert these two objects are equal,
// and export the object it created back to the caller.
/// # Safety
///
/// There is no safety
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roundtrip_test_case(
    id: u8,
    input: *const u8,
    input_len: usize,
    output: *mut *const u8,
    output_len: *mut usize,
) {
    unsafe {
        let input = std::slice::from_raw_parts(input, input_len);
        let out = run_test(id, input);
        *output = out.as_ptr();
        *output_len = out.len();
    };
}

fn run_test(id: u8, input: &[u8]) -> Vec<u8> {
    todo!()
}
