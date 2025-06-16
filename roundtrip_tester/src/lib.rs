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
    output: *mut *mut u8,
    output_len: *mut usize,
) {
    unsafe {
        let input = std::slice::from_raw_parts(input, input_len);
        let mut out = run_test(id, input);
        *output = out.as_mut_ptr();
        *output_len = out.len();
        std::mem::forget(out);
    };
}

#[derive(BorshSerialize, BorshDeserialize, PartialEq, Debug)]
struct TestCase0 {
    name: String,
    age: u128,
    prob: f64,
    data: Vec<i32>,
}

fn run_test(id: u8, input: &[u8]) -> Vec<u8> {
    match id {
        0 => run_case(input, TestCase0{
            name: "ccccc".to_owned(),
            age: 541212312321534534,
            prob: 0.69,
            data: vec![31, 69],
        }),
        _ => panic!("unknown id: {}", id),
    }
}

fn run_case<T: BorshSerialize + BorshDeserialize + PartialEq + std::fmt::Debug>(input: &[u8], output: T) -> Vec<u8> {
    let input: T = borsh::from_slice(input).unwrap();

    assert_eq!(input, output);

    let output = borsh::to_vec(&output).unwrap();

    return output;
}
