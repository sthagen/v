enum Token {
	aa = 2
	bb
	cc
}

fn test_map_with_enum_keys() {
	mut m := map[Token]string{}
	m[.aa] = 'abc'
	m[Token.bb] = 'def'
	assert m[Token.aa] == 'abc'
	assert m[.bb] == 'def'
	//
	s := '$m'
	assert s == "{aa: 'abc', bb: 'def'}"
	println(m)
}
