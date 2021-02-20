module arrays

fn test_min() {
	a := [8, 2, 6, 4]
	assert min<int>(a) == 2
	assert min<int>(a[2..]) == 4
	b := [f32(5.1), 3.1, 1.1, 9.1]
	assert min<f32>(b) == f32(1.1)
	assert min<f32>(b[..2]) == f32(3.1)
	c := [byte(4), 9, 3, 1]
	assert min<byte>(c) == byte(1)
	assert min<byte>(c[..3]) == byte(3)
}

fn test_max() {
	a := [8, 2, 6, 4]
	assert max<int>(a) == 8
	assert max<int>(a[1..]) == 6
	b := [f32(5.1), 3.1, 1.1, 9.1]
	assert max<f32>(b) == f32(9.1)
	assert max<f32>(b[..3]) == f32(5.1)
	c := [byte(4), 9, 3, 1]
	assert max<byte>(c) == byte(9)
	assert max<byte>(c[2..]) == byte(3)
}

fn test_idx_min() {
	a := [8, 2, 6, 4]
	assert idx_min<int>(a) == 1
	b := [f32(5.1), 3.1, 1.1, 9.1]
	assert idx_min<f32>(b) == 2
	c := [byte(4), 9, 3, 1]
	assert idx_min<byte>(c) == 3
}

fn test_idx_max() {
	a := [8, 2, 6, 4]
	assert idx_max<int>(a) == 0
	b := [f32(5.1), 3.1, 1.1, 9.1]
	assert idx_max<f32>(b) == 3
	c := [byte(4), 9, 3, 1]
	assert idx_max<byte>(c) == 1
}

fn test_merge() {
	a := [1, 3, 5, 5, 7]
	b := [2, 4, 4, 5, 6, 8]
	c := []int{}
	d := []int{}
	assert merge<int>(a, b) == [1, 2, 3, 4, 4, 5, 5, 5, 6, 7, 8]
	assert merge<int>(c, d) == []
	assert merge<int>(a, c) == a
	assert merge<int>(d, b) == b
}
