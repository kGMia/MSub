import MLX
// Axis 0 contiguous slices use gather_front and do not reproduce this crash.
// Scalar axis 1 forces Gather's general idx_ndim == 0 specialization.
let source = MLXArray(Array(0..<12)).reshaped(3, 4)
let scalar = MLXArray(Int32(1))
let gathered = take(source, scalar, axis: 1)
eval(gathered)
precondition(gathered.asArray(Int32.self) == [1, 5, 9])
let vector = take(source, MLXArray([Int32(2), 0]), axis: 0)
eval(vector)
precondition(vector.asArray(Int32.self) == [8, 9, 10, 11, 0, 1, 2, 3])
let columns = take(source, MLXArray([Int32(2), 0]), axis: 1)
eval(columns)
precondition(columns.asArray(Int32.self) == [2, 0, 6, 4, 10, 8])
let transposed = take(source.transposed(), scalar, axis: 0)
eval(transposed)
precondition(transposed.asArray(Int32.self) == [1, 5, 9])
print("PASS: scalar, vector, contiguous and transposed Metal gather")
