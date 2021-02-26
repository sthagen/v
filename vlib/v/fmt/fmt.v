// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module fmt

import v.ast
import v.table
import strings
import v.util
import v.pref

const (
	bs      = '\\'
	tabs    = ['', '\t', '\t\t', '\t\t\t', '\t\t\t\t', '\t\t\t\t\t', '\t\t\t\t\t\t', '\t\t\t\t\t\t\t',
		'\t\t\t\t\t\t\t\t',
	]
	// when to break a line dependant on penalty
	max_len = [0, 35, 60, 85, 93, 100]
)

pub struct Fmt {
pub mut:
	table              &table.Table
	out_imports        strings.Builder
	out                strings.Builder
	indent             int
	empty_line         bool
	line_len           int    // the current line length, NB: it counts \t as 4 spaces, and starts at 0 after f.writeln
	buffering          bool   // disables line wrapping for exprs that will be analyzed later
	par_level          int    // how many parentheses are put around the current expression
	array_init_break   []bool // line breaks after elements in hierarchy level of multi dimensional array
	array_init_depth   int    // current level of hierarchie in array init
	single_line_if     bool
	cur_mod            string
	cur_short_mod      string // TODO clean this up
	file               ast.File
	did_imports        bool
	is_assign          bool
	is_struct_init     bool
	auto_imports       []string        // automatically inserted imports that the user forgot to specify
	import_pos         int             // position of the imports in the resulting string for later autoimports insertion
	used_imports       []string        // to remove unused imports
	import_syms_used   map[string]bool // to remove unused import symbols.
	is_debug           bool
	mod2alias          map[string]string // for `import time as t`, will contain: 'time'=>'t'
	use_short_fn_args  bool
	single_line_fields bool   // should struct fields be on a single line
	it_name            string // the name to replace `it` with
	inside_lambda      bool
	inside_const       bool
	is_mbranch_expr    bool // math a { x...y { } }
	pref               &pref.Preferences
}

pub fn fmt(file ast.File, table &table.Table, pref &pref.Preferences, is_debug bool) string {
	mut f := Fmt{
		out: strings.new_builder(1000)
		out_imports: strings.new_builder(200)
		table: table
		indent: 0
		file: file
		is_debug: is_debug
		pref: pref
	}
	f.process_file_imports(file)
	f.set_current_module_name('main')
	// As these are toplevel stmts, the indent increase done in f.stmts() has to be compensated
	f.indent--
	f.stmts(file.stmts)
	f.indent++
	// for comment in file.comments { println('$comment.line_nr $comment.text')	}
	f.imports(f.file.imports) // now that we have all autoimports, handle them
	res := f.out.str().trim_space() + '\n'
	if res.len == 1 {
		return f.out_imports.str().trim_space() + '\n'
	}
	bounded_import_pos := util.imin(res.len, f.import_pos)
	return res[..bounded_import_pos] + f.out_imports.str() + res[bounded_import_pos..] // + '\n'
}

pub fn (mut f Fmt) process_file_imports(file &ast.File) {
	for imp in file.imports {
		mod := imp.mod.all_after_last('.')
		f.mod2alias[mod] = imp.alias
		for sym in imp.syms {
			f.mod2alias['${imp.mod}.$sym.name'] = sym.name
			f.mod2alias['${mod}.$sym.name'] = sym.name
			f.mod2alias[sym.name] = sym.name
			f.import_syms_used[sym.name] = false
		}
	}
	f.auto_imports = file.auto_imports
}

pub fn (mut f Fmt) write(s string) {
	if f.indent > 0 && f.empty_line {
		f.write_indent()
	}
	f.out.write_string(s)
	f.line_len += s.len
	f.empty_line = false
}

pub fn (mut f Fmt) writeln(s string) {
	if f.indent > 0 && f.empty_line && s.len > 0 {
		f.write_indent()
	}
	f.out.writeln(s)
	f.empty_line = true
	f.line_len = 0
}

fn (mut f Fmt) write_indent() {
	if f.indent < fmt.tabs.len {
		f.out.write_string(fmt.tabs[f.indent])
	} else {
		// too many indents, do it the slow way:
		for _ in 0 .. f.indent {
			f.out.write_string('\t')
		}
	}
	f.line_len += f.indent * 4
}

fn (mut f Fmt) write_language_prefix(lang table.Language) {
	match lang {
		.c { f.write('C.') }
		.js { f.write('JS.') }
		else {}
	}
}

pub fn (mut f Fmt) wrap_long_line(penalty_idx int, add_indent bool) bool {
	if f.buffering {
		return false
	}
	if penalty_idx > 0 && f.line_len <= fmt.max_len[penalty_idx] {
		return false
	}
	if f.out.buf[f.out.buf.len - 1] == ` ` {
		f.out.go_back(1)
	}
	f.write('\n')
	f.line_len = 0
	if add_indent {
		f.indent++
	}
	f.write_indent()
	if add_indent {
		f.indent--
	}
	return true
}

pub struct RemoveNewLineConfig {
	imports_buffer bool // Work on f.out_imports instead of f.out
}

pub fn (mut f Fmt) remove_new_line(cfg RemoveNewLineConfig) {
	mut buffer := if cfg.imports_buffer { &f.out_imports } else { &f.out }
	mut i := 0
	for i = buffer.len - 1; i >= 0; i-- {
		if !buffer.buf[i].is_space() { // != `\n` {
			break
		}
	}
	buffer.go_back(buffer.len - i - 1)
	f.empty_line = false
}

pub fn (mut f Fmt) set_current_module_name(cmodname string) {
	f.cur_mod = cmodname
	f.table.cmod_prefix = cmodname + '.'
}

fn (f Fmt) get_modname_prefix(mname string) (string, string) {
	// ./tests/proto_module_importing_vproto_keep.vv to know, why here is checked for ']' and '&'
	if !mname.contains(']') && !mname.contains('&') {
		return mname, ''
	}
	after_rbc := mname.all_after_last(']')
	after_ref := mname.all_after_last('&')
	modname := if after_rbc.len < after_ref.len { after_rbc } else { after_ref }
	return modname, mname.trim_suffix(modname)
}

fn (mut f Fmt) is_external_name(name string) bool {
	if name.len > 2 && name[0] == `C` && name[1] == `.` {
		return true
	}
	if name.len > 3 && name[0] == `J` && name[1] == `S` && name[2] == `.` {
		return true
	}
	return false
}

pub fn (mut f Fmt) no_cur_mod(typename string) string {
	return util.no_cur_mod(typename, f.cur_mod)
}

// foo.bar.fn() => bar.fn()
pub fn (mut f Fmt) short_module(name string) string {
	if !name.contains('.') {
		return name
	}
	if name in f.mod2alias {
		return f.mod2alias[name]
	}
	if name.ends_with('>') {
		x := name.trim_suffix('>').split('<')
		if x.len == 2 {
			main := f.short_module(x[0])
			genlist := x[1].split(',')
			genshorts := genlist.map(f.short_module(it)).join(',')
			return '$main<$genshorts>'
		}
	}
	vals := name.split('.')
	if vals.len < 2 {
		return name
	}
	mname, tprefix := f.get_modname_prefix(vals[vals.len - 2])
	symname := vals[vals.len - 1]
	aname := f.mod2alias[mname]
	if aname == '' {
		return symname
	}
	return '$tprefix${aname}.$symname'
}

pub fn (mut f Fmt) mod(mod ast.Module) {
	f.set_current_module_name(mod.name)
	f.cur_short_mod = mod.short_name
	if mod.is_skipped {
		return
	}
	f.attrs(mod.attrs)
	f.writeln('module $mod.short_name\n')
	if f.import_pos == 0 {
		f.import_pos = f.out.len
	}
}

pub fn (mut f Fmt) mark_types_import_as_used(typ table.Type) {
	sym := f.table.get_type_symbol(typ)
	f.mark_import_as_used(sym.name)
}

// `name` is a function (`foo.bar()`) or type (`foo.Bar{}`)
pub fn (mut f Fmt) mark_import_as_used(name string) {
	parts := name.split('.')
	last := parts.last()
	if last in f.import_syms_used {
		f.import_syms_used[last] = true
	}
	if parts.len == 1 {
		return
	}
	mod := parts[0..parts.len - 1].join('.')
	if mod in f.used_imports {
		return
	}
	f.used_imports << mod
}

pub fn (mut f Fmt) imports(imports []ast.Import) {
	if f.did_imports || imports.len == 0 {
		return
	}
	f.did_imports = true
	mut num_imports := 0
	mut already_imported := map[string]bool{}

	for imp in imports {
		if imp.mod !in f.used_imports {
			// TODO bring back once only unused imports are removed
			// continue
		}
		if imp.mod in f.auto_imports && imp.mod !in f.used_imports {
			continue
		}
		import_text := 'import ${f.imp_stmt_str(imp)}'
		if already_imported[import_text] {
			continue
		}
		already_imported[import_text] = true
		f.out_imports.writeln(import_text)
		f.import_comments(imp.comments, inline: true)
		f.import_comments(imp.next_comments, {})
		num_imports++
	}
	if num_imports > 0 {
		f.out_imports.writeln('')
	}
}

pub fn (f Fmt) imp_stmt_str(imp ast.Import) string {
	is_diff := imp.alias != imp.mod && !imp.mod.ends_with('.' + imp.alias)
	mut imp_alias_suffix := if is_diff { ' as $imp.alias' } else { '' }

	mut syms := imp.syms.map(it.name).filter(f.import_syms_used[it])
	syms.sort()
	if syms.len > 0 {
		imp_alias_suffix += if imp.syms[0].pos.line_nr == imp.pos.line_nr {
			' { ' + syms.join(', ') + ' }'
		} else {
			' {\n\t' + syms.join(',\n\t') + ',\n}'
		}
	}
	return '$imp.mod$imp_alias_suffix'
}

fn (f Fmt) should_insert_newline_before_stmt(stmt ast.Stmt, prev_stmt ast.Stmt) bool {
	prev_line_nr := prev_stmt.position().last_line
	// No need to insert a newline if there is already one
	if f.out.last_n(2) == '\n\n' {
		return false
	}
	// Force a newline after a block of HashStmts
	if prev_stmt is ast.HashStmt && stmt !is ast.HashStmt && stmt !is ast.ExprStmt {
		return true
	}
	// Force a newline after a block of function declarations
	if prev_stmt is ast.FnDecl {
		if prev_stmt.no_body && stmt !is ast.FnDecl {
			return true
		}
	}
	// The stmt shouldn't have a newline before
	if stmt.position().line_nr - prev_line_nr <= 1 {
		return false
	}
	// Imports are handled special hence they are ignored here
	if stmt is ast.Import || prev_stmt is ast.Import {
		return false
	}
	// Attributes are not respected in the stmts position, so this requires a manual check
	if stmt is ast.StructDecl {
		if stmt.attrs.len > 0 && stmt.attrs[0].pos.line_nr - prev_line_nr <= 1 {
			return false
		}
	}
	if stmt is ast.FnDecl {
		if stmt.attrs.len > 0 && stmt.attrs[0].pos.line_nr - prev_line_nr <= 1 {
			return false
		}
	}
	return true
}

pub fn (mut f Fmt) stmts(stmts []ast.Stmt) {
	mut prev_stmt := if stmts.len > 0 { stmts[0] } else { ast.Stmt{} }
	f.indent++
	for stmt in stmts {
		if !f.pref.building_v && f.should_insert_newline_before_stmt(stmt, prev_stmt) {
			f.out.writeln('')
		}
		f.stmt(stmt)
		prev_stmt = stmt
	}
	f.indent--
}

pub fn (mut f Fmt) stmt_str(node ast.Stmt) string {
	was_empty_line := f.empty_line
	prev_line_len := f.line_len
	pos := f.out.len
	f.stmt(node)
	str := f.out.after(pos).trim_space()
	f.out.go_back_to(pos)
	f.empty_line = was_empty_line
	f.line_len = prev_line_len
	return str
}

pub fn (mut f Fmt) stmt(node ast.Stmt) {
	if f.is_debug {
		eprintln('stmt: ${node.position():-42} | node: ${node.type_name():-20}')
	}
	match node {
		ast.AssignStmt {
			f.assign_stmt(node)
		}
		ast.AssertStmt {
			f.assert_stmt(node)
		}
		ast.Block {
			f.block(node)
		}
		ast.BranchStmt {
			f.writeln(node.str())
		}
		ast.CompFor {
			f.comp_for(node)
		}
		ast.ConstDecl {
			f.const_decl(node)
		}
		ast.DeferStmt {
			f.defer_stmt(node)
		}
		ast.EnumDecl {
			f.enum_decl(node)
		}
		ast.ExprStmt {
			f.expr_stmt(node)
		}
		ast.FnDecl {
			f.fn_decl(node)
		}
		ast.ForCStmt {
			f.for_c_stmt(node)
		}
		ast.ForInStmt {
			f.for_in_stmt(node)
		}
		ast.ForStmt {
			f.for_stmt(node)
		}
		ast.GlobalDecl {
			f.global_decl(node)
		}
		ast.GoStmt {
			f.go_stmt(node, false)
		}
		ast.GotoLabel {
			f.writeln('$node.name:')
		}
		ast.GotoStmt {
			f.writeln('goto $node.name')
		}
		ast.HashStmt {
			f.writeln('#$node.val')
		}
		ast.Import {
			// Imports are handled after the file is formatted, to automatically add necessary modules
			// Just remember the position of the imports for now
			f.import_pos = f.out.len
		}
		ast.InterfaceDecl {
			f.interface_decl(node)
		}
		ast.Module {
			f.mod(node)
		}
		ast.Return {
			f.return_stmt(node)
		}
		ast.SqlStmt {
			f.sql_stmt(node)
		}
		ast.StructDecl {
			f.struct_decl(node)
		}
		ast.TypeDecl {
			f.type_decl(node)
		}
	}
}

fn stmt_is_single_line(stmt ast.Stmt) bool {
	return match stmt {
		ast.ExprStmt, ast.AssertStmt { expr_is_single_line(stmt.expr) }
		ast.Return, ast.AssignStmt, ast.BranchStmt { true }
		else { false }
	}
}

pub fn (mut f Fmt) type_decl(node ast.TypeDecl) {
	mut comments := []ast.Comment{}
	match node {
		ast.AliasTypeDecl {
			if node.is_pub {
				f.write('pub ')
			}
			ptype := f.table.type_to_str(node.parent_type)
			f.write('type $node.name = $ptype')
			comments << node.comments
		}
		ast.FnTypeDecl {
			if node.is_pub {
				f.write('pub ')
			}
			typ_sym := f.table.get_type_symbol(node.typ)
			fn_typ_info := typ_sym.info as table.FnType
			fn_info := fn_typ_info.func
			fn_name := f.no_cur_mod(node.name)
			f.write('type $fn_name = fn (')
			for i, arg in fn_info.params {
				if arg.is_mut {
					f.write(arg.typ.share().str() + ' ')
				}
				f.write(arg.name)
				mut s := f.no_cur_mod(f.table.type_to_str(arg.typ))
				if arg.is_mut {
					if s.starts_with('&') {
						s = s[1..]
					}
				}
				is_last_arg := i == fn_info.params.len - 1
				should_add_type := true || is_last_arg
					|| fn_info.params[i + 1].typ != arg.typ
					|| (fn_info.is_variadic && i == fn_info.params.len - 2)
				if should_add_type {
					ns := if arg.name == '' { '' } else { ' ' }
					if fn_info.is_variadic && is_last_arg {
						f.write(ns + '...' + s)
					} else {
						f.write(ns + s)
					}
				}
				if !is_last_arg {
					f.write(', ')
				}
			}
			f.write(')')
			if fn_info.return_type.idx() != table.void_type_idx {
				ret_str := f.no_cur_mod(f.table.type_to_str(fn_info.return_type))
				f.write(' $ret_str')
			} else if fn_info.return_type.has_flag(.optional) {
				f.write(' ?')
			}
			comments << node.comments
		}
		ast.SumTypeDecl {
			if node.is_pub {
				f.write('pub ')
			}
			f.write('type $node.name = ')
			mut sum_type_names := []string{}
			for t in node.variants {
				sum_type_names << f.table.type_to_str(t.typ)
			}
			sum_type_names.sort()
			for i, name in sum_type_names {
				f.write(name)
				if i < sum_type_names.len - 1 {
					f.write(' | ')
				}
				if i < sum_type_names.len - 1 {
					f.wrap_long_line(3, true)
				}
			}
			comments << node.comments
		}
	}
	if comments.len > 0 {
		f.write(' ')
		f.comments(comments, has_nl: false)
	}
	f.writeln('\n')
}

[inline]
fn abs(v int) int {
	return if v >= 0 { v } else { -v }
}

const (
	threshold_to_align_struct = 8
)

struct StructFieldAlignInfo {
mut:
	first_line   int
	last_line    int
	max_type_len int
	max_len      int
}

fn (mut list []StructFieldAlignInfo) add_new_info(len int, type_len int, line int) {
	list << StructFieldAlignInfo{
		first_line: line
		last_line: line
		max_type_len: type_len
		max_len: len
	}
}

[direct_array_access]
fn (mut list []StructFieldAlignInfo) add_info(len int, type_len int, line int) {
	if list.len == 0 {
		list.add_new_info(len, type_len, line)
		return
	}
	i := list.len - 1
	if line - list[i].last_line > 1 {
		list.add_new_info(len, type_len, line)
		return
	}
	list[i].last_line = line
	if len > list[i].max_len {
		list[i].max_len = len
	}
	if type_len > list[i].max_type_len {
		list[i].max_type_len = type_len
	}
}

struct CommentAndExprAlignInfo {
mut:
	max_attrs_len int
	max_type_len  int
	first_line    int
	last_line     int
}

fn (mut list []CommentAndExprAlignInfo) add_new_info(attrs_len int, type_len int, line int) {
	list << CommentAndExprAlignInfo{
		max_attrs_len: attrs_len
		max_type_len: type_len
		first_line: line
		last_line: line
	}
}

fn (mut list []CommentAndExprAlignInfo) add_info(attrs_len int, type_len int, line int) {
	if list.len == 0 {
		list.add_new_info(attrs_len, type_len, line)
		return
	}
	i := list.len - 1
	if line - list[i].last_line > 1 {
		list.add_new_info(attrs_len, type_len, line)
		return
	}
	d_len := abs(list[i].max_attrs_len - attrs_len) + abs(list[i].max_type_len - type_len)
	if !(d_len < fmt.threshold_to_align_struct) {
		list.add_new_info(attrs_len, type_len, line)
		return
	}
	list[i].last_line = line
	if attrs_len > list[i].max_attrs_len {
		list[i].max_attrs_len = attrs_len
	}
	if type_len > list[i].max_type_len {
		list[i].max_type_len = type_len
	}
}

pub fn (mut f Fmt) struct_decl(node ast.StructDecl) {
	f.attrs(node.attrs)
	if node.is_pub {
		f.write('pub ')
	}
	if node.is_union {
		f.write('union ')
	} else {
		f.write('struct ')
	}
	f.write_language_prefix(node.language)
	name := node.name.after('.')
	f.write(name)
	if node.gen_types.len > 0 {
		f.write(' <')
		gtypes := node.gen_types.map(f.table.type_to_str(it)).join(', ')
		f.write(gtypes)
		f.write('>')
	}
	if node.fields.len == 0 && node.embeds.len == 0 && node.pos.line_nr == node.pos.last_line {
		f.writeln(' {}')
		return
	}
	f.writeln(' {')
	mut field_aligns := []StructFieldAlignInfo{}
	mut comment_aligns := []CommentAndExprAlignInfo{}
	mut default_expr_aligns := []CommentAndExprAlignInfo{}
	mut field_types := []string{cap: node.fields.len}
	for i, field in node.fields {
		mut ft := f.no_cur_mod(f.table.type_to_str(field.typ))
		if !ft.contains('C.') && !ft.contains('JS.') && !ft.contains('fn (') && !ft.contains('chan') {
			ft = f.short_module(ft)
		}
		field_types << ft
		attrs_len := inline_attrs_len(field.attrs)
		end_pos := field.pos.pos + field.pos.len
		mut comments_len := 0 // Length of comments between field name and type
		for comment in field.comments {
			if comment.pos.pos >= end_pos {
				if comment.pos.line_nr == field.pos.line_nr {
					comment_aligns.add_info(attrs_len, field_types[i].len, comment.pos.line_nr)
				}
				continue
			}
			if comment.pos.pos > field.pos.pos {
				comments_len += '/* ${comment.text.trim_left('\x01')} */ '.len
			}
		}
		field_aligns.add_info(comments_len + field.name.len, ft.len, field.pos.line_nr)
		if field.has_default_expr {
			default_expr_aligns.add_info(attrs_len, field_types[i].len, field.pos.line_nr)
		}
	}
	for embed in node.embeds {
		f.mark_types_import_as_used(embed.typ)
		styp := f.table.type_to_str(embed.typ)
		f.writeln('\t$styp')
	}
	mut field_align_i := 0
	mut comment_align_i := 0
	mut default_expr_align_i := 0
	mut inc_indent := false // for correct indents with multi line default exprs
	for i, field in node.fields {
		if i == node.mut_pos {
			f.writeln('mut:')
		} else if i == node.pub_pos {
			f.writeln('pub:')
		} else if i == node.pub_mut_pos {
			f.writeln('pub mut:')
		} else if i == node.global_pos {
			f.writeln('__global:')
		} else if i == node.module_pos {
			f.writeln('module:')
		} else if i > 0 {
			// keep one empty line between fields (exclude one after mut:, pub:, ...)
			mut before_last_line := node.fields[i - 1].pos.line_nr
			if node.fields[i - 1].comments.len > 0 {
				before_last_line = util.imax(before_last_line, node.fields[i - 1].comments.last().pos.last_line)
			}
			if node.fields[i - 1].has_default_expr {
				before_last_line = util.imax(before_last_line, node.fields[i - 1].default_expr.position().last_line)
			}

			mut next_first_line := field.pos.line_nr
			if field.comments.len > 0 {
				next_first_line = util.imin(next_first_line, field.comments[0].pos.line_nr)
			}
			if next_first_line - before_last_line > 1 {
				f.writeln('')
			}
		}
		end_pos := field.pos.pos + field.pos.len
		before_comments := field.comments.filter(it.pos.pos < field.pos.pos)
		between_comments := field.comments[before_comments.len..].filter(it.pos.pos < end_pos)
		after_type_comments := field.comments[(before_comments.len + between_comments.len)..]
		// Handle comments before the field
		f.comments_before_field(before_comments)
		f.write('\t$field.name ')
		// Handle comments between field name and type
		before_len := f.line_len
		f.comments(between_comments, iembed: true, has_nl: false)
		comments_len := f.line_len - before_len
		mut field_align := field_aligns[field_align_i]
		if field_align.last_line < field.pos.line_nr {
			field_align_i++
			field_align = field_aligns[field_align_i]
		}
		f.write(strings.repeat(` `, field_align.max_len - field.name.len - comments_len))
		f.write(field_types[i])
		f.mark_types_import_as_used(field.typ)
		attrs_len := inline_attrs_len(field.attrs)
		has_attrs := field.attrs.len > 0
		if has_attrs {
			f.write(strings.repeat(` `, field_align.max_type_len - field_types[i].len))
			f.inline_attrs(field.attrs)
		}
		if field.has_default_expr {
			mut align := default_expr_aligns[default_expr_align_i]
			if align.last_line < field.pos.line_nr {
				default_expr_align_i++
				align = default_expr_aligns[default_expr_align_i]
			}
			pad_len := align.max_attrs_len - attrs_len + align.max_type_len - field_types[i].len
			f.write(strings.repeat(` `, pad_len))
			f.write(' = ')
			if !expr_is_single_line(field.default_expr) {
				f.indent++
				inc_indent = true
			}
			f.prefix_expr_cast_expr(field.default_expr)
			if inc_indent {
				f.indent--
				inc_indent = false
			}
		}
		// Handle comments after field type
		if after_type_comments.len > 0 {
			if after_type_comments[0].pos.line_nr > field.pos.line_nr {
				f.writeln('')
			} else {
				if !field.has_default_expr {
					mut align := comment_aligns[comment_align_i]
					if align.last_line < field.pos.line_nr {
						comment_align_i++
						align = comment_aligns[comment_align_i]
					}
					pad_len := align.max_attrs_len - attrs_len + align.max_type_len - field_types[i].len
					f.write(strings.repeat(` `, pad_len))
				}
				f.write(' ')
			}
			f.comments(after_type_comments, level: .indent)
		} else {
			f.writeln('')
		}
	}
	f.comments_after_last_field(node.end_comments)
	f.writeln('}\n')
}

pub fn (mut f Fmt) interface_decl(node ast.InterfaceDecl) {
	if node.is_pub {
		f.write('pub ')
	}
	name := node.name.after('.')
	f.write('interface $name {')
	if node.fields.len > 0 || node.methods.len > 0 || node.pos.line_nr < node.pos.last_line {
		f.writeln('')
	}
	f.comments_after_last_field(node.pre_comments)
	for field in node.fields {
		// TODO: alignment, comments, etc.
		mut ft := f.no_cur_mod(f.table.type_to_str(field.typ))
		if !ft.contains('C.') && !ft.contains('JS.') && !ft.contains('fn (') {
			ft = f.short_module(ft)
		}
		f.writeln('\t$field.name $ft')
	}
	for method in node.methods {
		f.write('\t')
		f.write(method.stringify(f.table, f.cur_mod, f.mod2alias).after('fn '))
		f.comments(method.comments, inline: true, has_nl: false, level: .indent)
		f.writeln('')
		f.comments(method.next_comments, inline: false, has_nl: true, level: .indent)
	}
	f.writeln('}\n')
}

pub fn (mut f Fmt) enum_decl(node ast.EnumDecl) {
	f.attrs(node.attrs)
	if node.is_pub {
		f.write('pub ')
	}
	name := node.name.after('.')
	if node.fields.len == 0 && node.pos.line_nr == node.pos.last_line {
		f.writeln('enum $name {}\n')
		return
	}
	f.writeln('enum $name {')
	f.comments(node.comments, inline: true, level: .indent)
	for field in node.fields {
		f.write('\t$field.name')
		if field.has_expr {
			f.write(' = ')
			f.expr(field.expr)
		}
		f.comments(field.comments, inline: true, has_nl: false, level: .indent)
		f.writeln('')
		f.comments(field.next_comments, inline: false, has_nl: true, level: .indent)
	}
	f.writeln('}\n')
}

pub fn (mut f Fmt) prefix_expr_cast_expr(fexpr ast.Expr) {
	mut is_pe_amp_ce := false
	if fexpr is ast.PrefixExpr {
		if fexpr.right is ast.CastExpr && fexpr.op == .amp {
			mut ce := fexpr.right as ast.CastExpr
			ce.typname = f.table.get_type_symbol(ce.typ).name
			is_pe_amp_ce = true
			f.expr(ce)
		}
	} else if fexpr is ast.CastExpr {
		last := f.out.cut_last(1)
		if last != '&' {
			f.out.write_string(last)
		}
	}
	if !is_pe_amp_ce {
		f.expr(fexpr)
		if fexpr is ast.PrefixExpr {
			f.or_expr(fexpr.or_block)
		}
	}
}

pub fn (mut f Fmt) expr(node ast.Expr) {
	if f.is_debug {
		eprintln('expr: ${node.position():-42} | node: ${node.type_name():-20} | $node.str()')
	}
	match mut node {
		ast.CTempVar {
			eprintln('ast.CTempVar of $node.orig.str() should be generated/used only in cgen')
		}
		ast.AnonFn {
			f.fn_decl(node.decl)
		}
		ast.ArrayInit {
			f.array_init(node)
		}
		ast.AsCast {
			f.as_cast(node)
		}
		ast.Assoc {
			f.assoc(node)
		}
		ast.BoolLiteral {
			f.write(node.val.str())
		}
		ast.CastExpr {
			f.cast_expr(node)
		}
		ast.AtExpr {
			f.at_expr(node)
		}
		ast.CallExpr {
			f.call_expr(node)
		}
		ast.ChanInit {
			f.chan_init(mut node)
		}
		ast.CharLiteral {
			f.write('`$node.val`')
		}
		ast.Comment {
			f.comment(node, inline: true)
		}
		ast.ComptimeCall {
			f.comptime_call(node)
		}
		ast.ComptimeSelector {
			f.comptime_selector(node)
		}
		ast.ConcatExpr {
			f.concat_expr(node)
		}
		ast.EnumVal {
			f.enum_val(node)
		}
		ast.FloatLiteral {
			f.write(node.val)
		}
		ast.GoExpr {
			f.go_stmt(node.go_stmt, true)
		}
		ast.IfExpr {
			f.if_expr(node)
		}
		ast.Ident {
			f.ident(node)
		}
		ast.IfGuardExpr {
			f.if_guard_expr(node)
		}
		ast.InfixExpr {
			f.infix_expr(node)
		}
		ast.IndexExpr {
			f.index_expr(node)
		}
		ast.IntegerLiteral {
			f.write(node.val)
		}
		ast.LockExpr {
			f.lock_expr(node)
		}
		ast.MapInit {
			f.map_init(node)
		}
		ast.MatchExpr {
			f.match_expr(node)
		}
		ast.None {
			f.write('none')
		}
		ast.OrExpr {
			// shouldn't happen, an or expression is always linked to a call expr
			panic('fmt: OrExpr should be linked to CallExpr')
		}
		ast.ParExpr {
			f.par_expr(node)
		}
		ast.PostfixExpr {
			f.postfix_expr(node)
		}
		ast.PrefixExpr {
			f.prefix_expr(node)
		}
		ast.RangeExpr {
			f.range_expr(node)
		}
		ast.SelectExpr {
			f.select_expr(node)
		}
		ast.SelectorExpr {
			f.selector_expr(node)
		}
		ast.SizeOf {
			f.size_of(node)
		}
		ast.OffsetOf {
			f.write('__offsetof(${f.table.type_to_str(node.struct_type)}, $node.field)')
		}
		ast.SqlExpr {
			f.sql_expr(node)
		}
		ast.StringLiteral {
			f.string_literal(node)
		}
		ast.StringInterLiteral {
			f.string_inter_literal(node)
		}
		ast.StructInit {
			f.struct_init(node)
		}
		ast.Type {
			f.write(f.table.type_to_str(node.typ))
		}
		ast.TypeOf {
			f.type_of(node)
		}
		ast.Likely {
			f.likely(node)
		}
		ast.UnsafeExpr {
			f.unsafe_expr(node)
		}
		ast.ArrayDecompose {
			f.array_decompose(node)
		}
	}
}

fn expr_is_single_line(expr ast.Expr) bool {
	match expr {
		ast.AnonFn {
			if !expr.decl.no_body {
				return false
			}
		}
		ast.IfExpr {
			return false
		}
		ast.Comment {
			return false
		}
		ast.MatchExpr {
			return false
		}
		ast.StructInit {
			if !expr.is_short && (expr.fields.len > 0 || expr.pre_comments.len > 0) {
				return false
			}
		}
		ast.CallExpr {
			if expr.or_block.stmts.len > 1 {
				return false
			}
		}
		ast.ArrayInit {
			if expr.exprs.len > 0 {
				return expr_is_single_line(expr.exprs[0])
			}
		}
		else {}
	}
	return true
}

pub fn (mut f Fmt) or_expr(node ast.OrExpr) {
	match node.kind {
		.absent {}
		.block {
			if node.stmts.len == 0 {
				f.write(' or { }')
				return
			} else if node.stmts.len == 1 && stmt_is_single_line(node.stmts[0]) {
				// the control stmts (return/break/continue...) print a newline inside them,
				// so, since this'll all be on one line, trim any possible whitespace
				str := f.stmt_str(node.stmts[0]).trim_space()
				single_line := ' or { $str }'
				if single_line.len + f.line_len <= fmt.max_len.last() {
					f.write(single_line)
					return
				}
			}
			// Make it multiline if the blocks has at least two stmts
			// or a single line would be too long
			f.writeln(' or {')
			f.stmts(node.stmts)
			f.write('}')
		}
		.propagate {
			f.write(' ?')
		}
	}
}

fn (mut f Fmt) attrs(attrs []table.Attr) {
	for attr in attrs {
		f.writeln('[$attr]')
	}
}

fn (mut f Fmt) inline_attrs(attrs []table.Attr) {
	if attrs.len == 0 {
		return
	}
	f.write(' [')
	for i, attr in attrs {
		if i > 0 {
			f.write('; ')
		}
		f.write('$attr')
	}
	f.write(']')
}

fn inline_attrs_len(attrs []table.Attr) int {
	if attrs.len == 0 {
		return 0
	}
	mut n := 2 // ' ['.len
	for i, attr in attrs {
		if i > 0 {
			n += 2 // '; '.len
		}
		n += '$attr'.len
	}
	n++ // ']'.len
	return n
}

pub fn (mut f Fmt) fn_decl(node ast.FnDecl) {
	f.attrs(node.attrs)
	f.write(node.stringify(f.table, f.cur_mod, f.mod2alias)) // `Expr` instead of `ast.Expr` in mod ast
	if node.language == .v {
		if !node.no_body {
			f.write(' {')
			if node.stmts.len > 0 || node.pos.line_nr < node.pos.last_line {
				f.writeln('')
				f.stmts(node.stmts)
			}
			f.write('}')
		}
		if !node.is_anon {
			f.writeln('')
		}
	} else {
		f.writeln('')
	}
	// Mark all function's used type so that they are not removed from imports
	for arg in node.params {
		f.mark_types_import_as_used(arg.typ)
	}
	f.mark_types_import_as_used(node.return_type)
}

pub fn (mut f Fmt) as_cast(node ast.AsCast) {
	type_str := f.table.type_to_str(node.typ)
	f.expr(node.expr)
	f.write(' as $type_str')
}

pub fn (mut f Fmt) cast_expr(node ast.CastExpr) {
	f.write(f.table.type_to_str(node.typ) + '(')
	f.expr(node.expr)
	if node.has_arg {
		f.write(', ')
		f.expr(node.arg)
	}
	f.write(')')
}

pub fn (mut f Fmt) assoc(node ast.Assoc) {
	f.writeln('{')
	f.indent++
	f.writeln('...$node.var_name')
	for i, field in node.fields {
		f.write('$field: ')
		f.expr(node.exprs[i])
		f.writeln('')
	}
	f.indent--
	f.write('}')
}

pub fn (mut f Fmt) comptime_call(node ast.ComptimeCall) {
	if node.is_vweb {
		if node.method_name == 'html' {
			f.write('\$vweb.html()')
		} else {
			f.write("\$tmpl('$node.args_var')")
		}
	} else {
		if node.is_embed {
			f.write("\$embed_file('$node.embed_file.rpath')")
		} else if node.is_env {
			f.write("\$env('$node.args_var')")
		} else {
			method_expr := if node.has_parens {
				'(${node.method_name}($node.args_var))'
			} else {
				'${node.method_name}($node.args_var)'
			}
			f.write('${node.left}.$$method_expr')
		}
	}
}

pub fn (mut f Fmt) comptime_selector(node ast.ComptimeSelector) {
	f.write('${node.left}.\$($node.field_expr)')
}

pub fn (mut f Fmt) concat_expr(node ast.ConcatExpr) {
	for i, val in node.vals {
		if i != 0 {
			f.write(', ')
		}
		f.expr(val)
	}
}

pub fn (mut f Fmt) enum_val(node ast.EnumVal) {
	name := f.short_module(node.enum_name)
	f.write(name + '.' + node.val)
}

pub fn (mut f Fmt) ident(node ast.Ident) {
	if mut node.info is ast.IdentVar {
		if node.info.is_mut {
			f.write(node.info.share.str() + ' ')
		}
	}
	f.write_language_prefix(node.language)
	if node.name == 'it' && f.it_name != '' && !f.inside_lambda { // allow `it` in lambdas
		f.write(f.it_name)
	} else if node.kind == .blank_ident {
		f.write('_')
	} else {
		// Force usage of full path to const in the same module:
		// `println(minute)` => `println(time.minute)`
		// This makes it clear that a module const is being used
		// (since V's conts are no longer ALL_CAP).
		// ^^^ except for `main`, where consts are allowed to not have a `main.` prefix.
		if !node.name.contains('.') && !f.inside_const {
			mod := if f.cur_mod == '' { f.cur_short_mod } else { f.cur_mod } // TODO why is this needed?
			full_name := mod + '.' + node.name
			if obj := f.file.global_scope.find(full_name) {
				if obj is ast.ConstField {
					// "v.fmt.foo" => "fmt.foo"
					vals := full_name.split('.')
					mod_prefix := vals[vals.len - 2]
					const_name := vals[vals.len - 1]
					if mod_prefix == 'main' {
						f.write(const_name)
						return
					} else {
						short := mod_prefix + '.' + const_name
						f.write(short)
						f.mark_import_as_used(short)
						return
					}
				}
			}
		}
		name := f.short_module(node.name)
		f.write(name)
		f.mark_import_as_used(name)
	}
}

pub fn (mut f Fmt) if_guard_expr(node ast.IfGuardExpr) {
	f.write(node.var_name + ' := ')
	f.expr(node.expr)
}

pub fn (mut f Fmt) index_expr(node ast.IndexExpr) {
	f.expr(node.left)
	f.write('[')
	f.expr(node.index)
	f.write(']')
	if node.or_expr.kind != .absent {
		f.or_expr(node.or_expr)
	}
}

pub fn (mut f Fmt) par_expr(node ast.ParExpr) {
	f.write('(')
	f.par_level++
	f.expr(node.expr)
	f.par_level--
	f.write(')')
}

pub fn (mut f Fmt) postfix_expr(node ast.PostfixExpr) {
	f.expr(node.expr)
	// `$if foo ?`
	if node.op == .question {
		f.write(' ?')
	} else {
		f.write('$node.op')
	}
}

pub fn (mut f Fmt) prefix_expr(node ast.PrefixExpr) {
	f.write(node.op.str())
	f.prefix_expr_cast_expr(node.right)
}

pub fn (mut f Fmt) range_expr(node ast.RangeExpr) {
	f.expr(node.low)
	if f.is_mbranch_expr {
		f.write('...')
	} else {
		f.write('..')
	}
	f.expr(node.high)
}

pub fn (mut f Fmt) select_expr(node ast.SelectExpr) {
	f.writeln('select {')
	f.indent++
	for branch in node.branches {
		if branch.comment.text != '' {
			f.comment(branch.comment, inline: true)
			f.writeln('')
		}
		if branch.is_else {
			f.write('else {')
		} else {
			if branch.is_timeout {
				f.write('> ')
			}
			f.single_line_if = true
			match branch.stmt {
				ast.ExprStmt { f.expr(branch.stmt.expr) }
				else { f.stmt(branch.stmt) }
			}
			f.single_line_if = false
			f.write(' {')
		}
		if branch.stmts.len > 0 {
			f.writeln('')
			f.stmts(branch.stmts)
		}
		f.writeln('}')
		if branch.post_comments.len > 0 {
			f.comments(branch.post_comments, inline: true)
		}
	}
	f.indent--
	f.write('}')
}

pub fn (mut f Fmt) selector_expr(node ast.SelectorExpr) {
	f.expr(node.expr)
	f.write('.')
	f.write(node.field_name)
}

pub fn (mut f Fmt) size_of(node ast.SizeOf) {
	f.write('sizeof(')
	if node.is_type {
		sym := f.table.get_type_symbol(node.typ)
		if sym.name != '' {
			if f.is_external_name(sym.name) {
				f.write(sym.name)
			} else {
				f.write(f.short_module(sym.name))
			}
		} else {
			f.write(f.table.type_to_str(node.typ))
		}
	} else {
		f.expr(node.expr)
	}
	f.write(')')
}

pub fn (mut f Fmt) sql_expr(node ast.SqlExpr) {
	// sql app.db { select from Contributor where repo == id && user == 0 }
	f.write('sql ')
	f.expr(node.db_expr)
	f.writeln(' {')
	f.write('\tselect ')
	table_name := util.strip_mod_name(f.table.get_type_symbol(node.table_expr.typ).name)
	if node.is_count {
		f.write('count ')
	} else {
		for i, fd in node.fields {
			f.write(fd.name)
			if i < node.fields.len - 1 {
				f.write(', ')
			}
		}
	}
	f.write('from $table_name')
	if node.has_where {
		f.write(' where ')
		f.expr(node.where_expr)
	}
	if node.has_order {
		f.write(' order by ')
		f.expr(node.order_expr)
		if node.has_desc {
			f.write(' desc')
		}
	}
	if node.has_limit {
		f.write(' limit ')
		f.expr(node.limit_expr)
	}
	if node.has_offset {
		f.write(' offset ')
		f.expr(node.offset_expr)
	}
	f.writeln('')
	f.write('}')
}

pub fn (mut f Fmt) string_literal(node ast.StringLiteral) {
	use_double_quote := node.val.contains("'") && !node.val.contains('"')
	if node.is_raw {
		f.write('r')
	} else if node.language == table.Language.c {
		f.write('c')
	}
	if node.is_raw {
		if use_double_quote {
			f.write('"$node.val"')
		} else {
			f.write("'$node.val'")
		}
	} else {
		unescaped_val := node.val.replace('$fmt.bs$fmt.bs', '\x01').replace_each(["$fmt.bs'", "'",
			'$fmt.bs"', '"'])
		if use_double_quote {
			s := unescaped_val.replace_each(['\x01', '$fmt.bs$fmt.bs', '"', '$fmt.bs"'])
			f.write('"$s"')
		} else {
			s := unescaped_val.replace_each(['\x01', '$fmt.bs$fmt.bs', "'", "$fmt.bs'"])
			f.write("'$s'")
		}
	}
}

pub fn (mut f Fmt) string_inter_literal(node ast.StringInterLiteral) {
	// TODO: this code is very similar to ast.Expr.str()
	mut quote := "'"
	for val in node.vals {
		if val.contains("'") {
			quote = '"'
		}
		if val.contains('"') {
			quote = "'"
			break
		}
	}
	f.write(quote)
	for i, val in node.vals {
		f.write(val)
		if i >= node.exprs.len {
			break
		}
		f.write('$')
		fspec_str, needs_braces := node.get_fspec_braces(i)
		if needs_braces {
			f.write('{')
			f.expr(node.exprs[i])
			f.write(fspec_str)
			f.write('}')
		} else {
			f.expr(node.exprs[i])
		}
	}
	f.write(quote)
}

pub fn (mut f Fmt) type_of(node ast.TypeOf) {
	f.write('typeof(')
	f.expr(node.expr)
	f.write(')')
}

pub fn (mut f Fmt) likely(node ast.Likely) {
	if node.is_likely {
		f.write('_likely_')
	} else {
		f.write('_unlikely_')
	}
	f.write('(')
	f.expr(node.expr)
	f.write(')')
}

pub fn (mut f Fmt) unsafe_expr(node ast.UnsafeExpr) {
	single_line := node.pos.line_nr >= node.pos.last_line
	f.write('unsafe {')
	if single_line {
		f.write(' ')
	} else {
		f.writeln('')
		f.indent++
		f.empty_line = true
	}
	f.expr(node.expr)
	if single_line {
		f.write(' ')
	} else {
		f.writeln('')
		f.indent--
	}
	f.write('}')
}

pub fn (mut f Fmt) array_decompose(node ast.ArrayDecompose) {
	f.write('...')
	f.expr(node.expr)
}

pub fn (mut f Fmt) lock_expr(lex ast.LockExpr) {
	mut num_locked := 0
	mut num_rlocked := 0
	for is_rlock in lex.is_rlock {
		if is_rlock {
			num_rlocked++
		} else {
			num_locked++
		}
	}
	if num_locked > 0 || num_rlocked == 0 {
		f.write('lock ')
		mut n := 0
		for i, v in lex.lockeds {
			if !lex.is_rlock[i] {
				if n > 0 {
					f.write(', ')
				}
				f.expr(v)
				n++
			}
		}
	}
	if num_rlocked > 0 {
		if num_locked > 0 {
			f.write('; ')
		}
		f.write('rlock ')
		mut n := 0
		for i, v in lex.lockeds {
			if lex.is_rlock[i] {
				if n > 0 {
					f.write(', ')
				}
				f.expr(v)
				n++
			}
		}
	}
	f.write(' {')
	f.writeln('')
	f.stmts(lex.stmts)
	f.write('}')
}

pub fn (mut f Fmt) infix_expr(node ast.InfixExpr) {
	buffering_save := f.buffering
	if !f.buffering && node.op in [.logical_or, .and, .plus] {
		f.buffering = true
	}
	is_assign_save := f.is_assign
	if node.op == .left_shift {
		f.is_assign = true // To write ternary if on a single line
	}
	start_pos := f.out.len
	start_len := f.line_len
	f.expr(node.left)
	is_one_val_array_init := node.op in [.key_in, .not_in] && node.right is ast.ArrayInit
		&& (node.right as ast.ArrayInit).exprs.len == 1
	if is_one_val_array_init {
		// `var in [val]` => `var == val`
		op := if node.op == .key_in { ' == ' } else { ' != ' }
		f.write(op)
	} else {
		f.write(' $node.op.str() ')
	}
	if is_one_val_array_init {
		// `var in [val]` => `var == val`
		f.expr((node.right as ast.ArrayInit).exprs[0])
	} else {
		f.expr(node.right)
	}
	if !buffering_save && f.buffering {
		f.buffering = false
		if !f.single_line_if && f.line_len > fmt.max_len.last() {
			f.wrap_infix(start_pos, start_len, false)
		}
	}
	f.is_assign = is_assign_save
	f.or_expr(node.or_block)
}

pub fn (mut f Fmt) wrap_infix(start_pos int, start_len int, ignore_paren bool) {
	cut_span := f.out.len - start_pos
	condstr := f.out.cut_last(cut_span)
	is_cond_infix := condstr.contains_any_substr(['&&', '||'])
	if !is_cond_infix && !condstr.contains('+') {
		f.write(condstr)
		return
	}
	f.line_len = start_len
	if start_len == 0 {
		f.empty_line = true
	}
	or_pen := if condstr.contains('&&') { 3 } else { 5 }
	cond_parts := condstr.split(' ')
	mut grouped_cond := false
	mut conditions := ['']
	mut penalties := [5]
	mut index := 0
	for cp in cond_parts {
		if is_cond_infix && cp in ['&&', '||'] {
			if grouped_cond {
				conditions[index] += '$cp '
			} else {
				p := if cp == '||' { or_pen } else { 5 }
				penalties << p
				conditions << '$cp '
				index++
			}
		} else if !is_cond_infix && cp == '+' {
			penalties << 5
			conditions[index] += '$cp '
			conditions << ''
			index++
		} else {
			conditions[index] += '$cp '
			if ignore_paren {
				continue
			}
			if cp.starts_with('(') {
				grouped_cond = true
			} else if cp.ends_with(')') {
				grouped_cond = false
			}
		}
	}
	for i, c in conditions {
		cnd := c.trim_space()
		if f.line_len + cnd.len < fmt.max_len[penalties[i]] {
			if (i > 0 && i < conditions.len) || (ignore_paren && i == 0 && cnd[3] == `(`) {
				f.write(' ')
			}
			f.write(cnd)
		} else {
			prev_len := f.line_len
			prev_pos := f.out.len
			f.writeln('')
			f.indent++
			f.write(cnd)
			f.indent--
			if f.line_len > fmt.max_len.last() && (cnd[0] == `(` || cnd[3] == `(`)
				&& cnd.ends_with(')') {
				f.wrap_infix(prev_pos, prev_len, true)
			}
		}
	}
}

pub fn (mut f Fmt) if_expr(node ast.IfExpr) {
	dollar := if node.is_comptime { '$' } else { '' }
	mut is_ternary := node.branches.len == 2 && node.has_else
		&& branch_is_single_line(node.branches[0]) && branch_is_single_line(node.branches[1])
		&& (node.is_expr || f.is_assign || f.is_struct_init || f.single_line_fields)
	f.single_line_if = is_ternary
	start_pos := f.out.len
	start_len := f.line_len
	for {
		for i, branch in node.branches {
			if i == 0 {
				// first `if`
				f.comments(branch.comments, {})
			} else {
				// `else`, close previous branch
				if branch.comments.len > 0 {
					f.writeln('}')
					f.comments(branch.comments, {})
				} else {
					f.write('} ')
				}
				f.write('${dollar}else ')
			}
			if i < node.branches.len - 1 || !node.has_else {
				f.write('${dollar}if ')
				cur_pos := f.out.len
				f.expr(branch.cond)
				cond_len := f.out.len - cur_pos
				is_cond_wrapped := cond_len > 0
					&& (branch.cond is ast.IfGuardExpr || branch.cond is ast.CallExpr)
					&& '\n' in f.out.last_n(cond_len)
				if is_cond_wrapped {
					f.writeln('')
				} else {
					f.write(' ')
				}
			}
			f.write('{')
			if is_ternary {
				f.write(' ')
			} else {
				f.writeln('')
			}
			f.stmts(branch.stmts)
			if is_ternary {
				f.write(' ')
			}
		}
		// When a single line if is really long, write it again as multiline,
		// except it is part of an InfixExpr.
		if is_ternary && f.line_len > fmt.max_len.last() && !f.buffering {
			is_ternary = false
			f.single_line_if = false
			f.out.go_back_to(start_pos)
			f.line_len = start_len
			f.empty_line = start_len == 0
			continue
		}
		break
	}
	f.write('}')
	f.single_line_if = false
	if node.post_comments.len > 0 {
		f.writeln('')
		f.comments(node.post_comments, 
			has_nl: false
			prev_line: node.branches.last().body_pos.last_line
		)
	}
}

fn branch_is_single_line(b ast.IfBranch) bool {
	if b.stmts.len == 1 && b.comments.len == 0 && stmt_is_single_line(b.stmts[0]) {
		return true
	}
	return false
}

pub fn (mut f Fmt) at_expr(node ast.AtExpr) {
	f.write(node.name)
}

fn (mut f Fmt) write_generic_if_require(node ast.CallExpr) {
	if node.generic_types.len > 0 {
		f.write('<')
		for i, generic_type in node.generic_types {
			is_last := i == node.generic_types.len - 1
			f.write(f.table.type_to_str(generic_type))
			if !is_last {
				f.write(', ')
			}
		}
		f.write('>')
	}
}

pub fn (mut f Fmt) call_args(args []ast.CallArg) {
	f.single_line_fields = true
	for i, arg in args {
		if arg.is_mut {
			f.write(arg.share.str() + ' ')
		}
		if i > 0 && !f.single_line_if {
			f.wrap_long_line(3, true)
		}
		f.expr(arg.expr)
		if i < args.len - 1 {
			f.write(', ')
		}
	}
	f.single_line_fields = false
}

pub fn (mut f Fmt) call_expr(node ast.CallExpr) {
	old_short_arg_state := f.use_short_fn_args
	f.use_short_fn_args = false
	if node.args.len > 0 && node.args.last().expr is ast.StructInit {
		struct_expr := node.args.last().expr as ast.StructInit
		if struct_expr.typ == table.void_type {
			f.use_short_fn_args = true
		}
	}
	for arg in node.args {
		f.comments(arg.comments, {})
	}
	if node.is_method {
		if node.name in ['map', 'filter'] {
			f.inside_lambda = true
			defer {
				f.inside_lambda = false
			}
		}
		if node.left is ast.Ident {
			// `time.now()` without `time imported` is processed as a method call with `time` being
			// a `node.left` expression. Import `time` automatically.
			// TODO fetch all available modules
			if node.left.name in ['time', 'os', 'strings', 'math', 'json', 'base64'] {
				f.file.imports << ast.Import{
					mod: node.left.name
					alias: node.left.name
				}
			}
		}
		f.expr(node.left)
		f.write('.' + node.name)
	} else {
		f.write_language_prefix(node.language)
		if node.left is ast.AnonFn {
			f.fn_decl(node.left.decl)
		} else if node.language != .v {
			f.write('${node.name.after_char(`.`)}')
		} else {
			mut name := f.short_module(node.name)
			f.mark_import_as_used(name)
			if node.name in f.mod2alias {
				name = f.mod2alias[node.name]
			}
			f.write('$name')
		}
	}
	if node.mod == '' && node.name == '' {
		f.write(node.left.str())
	}
	f.write_generic_if_require(node)
	f.write('(')
	f.call_args(node.args)
	f.write(')')
	f.or_expr(node.or_block)
	f.comments(node.comments, has_nl: false)
	f.use_short_fn_args = old_short_arg_state
}

pub fn (mut f Fmt) match_expr(it ast.MatchExpr) {
	f.write('match ')
	f.expr(it.cond)
	if it.cond is ast.Ident {
		f.it_name = it.cond.name
	}
	f.writeln(' {')
	f.indent++
	f.comments(it.comments, {})
	mut single_line := true
	for branch in it.branches {
		if branch.stmts.len > 1 || branch.pos.line_nr < branch.pos.last_line {
			// println(branch)
			single_line = false
			break
		}
		if branch.stmts.len == 0 {
			continue
		}
		if !stmt_is_single_line(branch.stmts[0]) {
			single_line = false
			break
		}
	}
	for branch in it.branches {
		if !branch.is_else {
			// normal branch
			f.is_mbranch_expr = true
			for j, expr in branch.exprs {
				f.expr(expr)
				if j < branch.ecmnts.len && branch.ecmnts[j].len > 0 {
					f.write(' ')
					for cmnt in branch.ecmnts[j] {
						f.comment(cmnt, iembed: true)
					}
				}
				if j < branch.exprs.len - 1 {
					f.write(', ')
				}
				f.wrap_long_line(4, false)
			}
			f.is_mbranch_expr = false
		} else {
			// else branch
			f.write('else')
		}
		if branch.stmts.len == 0 {
			f.writeln(' {}')
		} else {
			if single_line {
				f.write(' { ')
			} else {
				f.writeln(' {')
			}
			f.stmts(branch.stmts)
			if single_line {
				f.remove_new_line({})
				f.writeln(' }')
			} else {
				f.writeln('}')
			}
		}
		if branch.post_comments.len > 0 {
			f.comments(branch.post_comments, inline: true)
		}
	}
	f.indent--
	f.write('}')
	f.it_name = ''
}

pub fn (mut f Fmt) chan_init(mut it ast.ChanInit) {
	info := f.table.get_type_symbol(it.typ).chan_info()
	if it.elem_type == 0 && it.typ > 0 {
		it.elem_type = info.elem_type
	}
	is_mut := info.is_mut
	el_typ := if is_mut {
		it.elem_type.set_nr_muls(it.elem_type.nr_muls() - 1)
	} else {
		it.elem_type
	}
	f.write('chan ')
	if is_mut {
		f.write('mut ')
	}
	f.write(f.table.type_to_str(el_typ))
	f.write('{')
	if it.has_cap {
		f.write('cap: ')
		f.expr(it.cap_expr)
	}
	f.write('}')
}

fn should_decrease_arr_penalty(e ast.Expr) bool {
	if e is ast.ArrayInit || e is ast.StructInit || e is ast.MapInit || e is ast.CallExpr {
		return true
	}
	return false
}

pub fn (mut f Fmt) array_init(node ast.ArrayInit) {
	if node.exprs.len == 0 && node.typ != 0 && node.typ != table.void_type {
		// `x := []string{}`
		f.mark_types_import_as_used(node.typ)
		f.write(f.table.type_to_str_using_aliases(node.typ, f.mod2alias))
		f.write('{')
		if node.has_len {
			f.write('len: ')
			f.expr(node.len_expr)
			if node.has_cap || node.has_default {
				f.write(', ')
			}
		}
		if node.has_cap {
			f.write('cap: ')
			f.expr(node.cap_expr)
			if node.has_default {
				f.write(', ')
			}
		}
		if node.has_default {
			f.write('init: ')
			f.expr(node.default_expr)
		}
		f.write('}')
		return
	}
	// `[1,2,3]`
	f.write('[')
	mut inc_indent := false
	mut last_line_nr := node.pos.line_nr // to have the same newlines between array elements
	f.array_init_depth++
	if node.pre_cmnts.len > 0 {
		if node.pre_cmnts[0].pos.line_nr > last_line_nr {
			f.writeln('')
		}
	}
	for i, c in node.pre_cmnts {
		if i < node.pre_cmnts.len - 1 {
			if c.pos.last_line < node.pre_cmnts[i + 1].pos.line_nr {
				f.comment(c, level: .indent)
				f.writeln('')
			} else {
				f.comment(c, level: .indent, iembed: true)
				f.write(' ')
			}
		} else {
			if c.pos.last_line < node.pos.last_line {
				f.comment(c, level: .indent)
				if node.exprs.len == 0 {
					f.writeln('')
				}
			} else {
				f.comment(c, level: .indent, iembed: true)
				if node.exprs.len > 0 {
					f.write(' ')
				}
			}
		}
		last_line_nr = c.pos.last_line
	}
	mut set_comma := false
	for i, expr in node.exprs {
		pos := expr.position()
		if i == 0 {
			if f.array_init_depth > f.array_init_break.len {
				f.array_init_break << pos.line_nr > last_line_nr
			}
		}
		line_break := f.array_init_break[f.array_init_depth - 1]
		mut penalty := if line_break { 0 } else { 4 }
		if penalty > 0 {
			if i == 0 || should_decrease_arr_penalty(node.exprs[i - 1]) {
				penalty--
			}
			if should_decrease_arr_penalty(expr) {
				penalty--
			}
		}
		is_new_line := f.wrap_long_line(penalty, !inc_indent)
		if is_new_line && !inc_indent {
			f.indent++
			inc_indent = true
		}
		if !is_new_line && i > 0 {
			f.write(' ')
		}
		f.expr(expr)
		if i < node.ecmnts.len && node.ecmnts[i].len > 0 {
			expr_pos := expr.position()
			for cmt in node.ecmnts[i] {
				if !set_comma && cmt.pos.pos > expr_pos.pos + expr_pos.len + 2 {
					f.write(',')
					set_comma = true
				}
				if cmt.pos.line_nr > expr_pos.last_line {
					f.writeln('')
					f.comment(cmt, {})
				} else {
					f.write(' ')
					f.comment(cmt, iembed: true)
				}
			}
		}
		if i == node.exprs.len - 1 {
			if is_new_line {
				if !set_comma {
					f.write(',')
				}
				f.writeln('')
			}
		} else if !set_comma {
			f.write(',')
		}
		last_line_nr = pos.last_line
		set_comma = false
	}
	f.array_init_depth--
	if f.array_init_depth == 0 {
		f.array_init_break = []
	}
	if inc_indent {
		f.indent--
	}
	f.write(']')
	// `[100]byte`
	if node.is_fixed {
		if node.has_val {
			f.write('!')
			return
		}
		f.write(f.table.type_to_str(node.elem_type))
		if node.has_default {
			f.write('{init: ')
			f.expr(node.default_expr)
			f.write('}')
		} else {
			f.write('{}')
		}
	}
}

pub fn (mut f Fmt) map_init(it ast.MapInit) {
	if it.keys.len == 0 {
		if it.typ > table.void_type {
			f.mark_types_import_as_used(it.typ)
			f.write(f.table.type_to_str(it.typ))
		} else {
			// m = map{}
			f.write('map')
		}
		f.write('{}')
		return
	}
	f.writeln('map{')
	f.indent++
	f.comments(it.pre_cmnts, {})
	mut max_field_len := 0
	for key in it.keys {
		if key.str().len > max_field_len {
			max_field_len = key.str().len
		}
	}
	for i, key in it.keys {
		f.expr(key)
		f.write(': ')
		f.write(strings.repeat(` `, max_field_len - key.str().len))
		f.expr(it.vals[i])
		f.comments(it.comments[i], prev_line: it.vals[i].position().last_line, has_nl: false)
		f.writeln('')
	}
	f.indent--
	f.write('}')
}

pub fn (mut f Fmt) struct_init(it ast.StructInit) {
	struct_init_save := f.is_struct_init
	f.is_struct_init = true
	defer {
		f.is_struct_init = struct_init_save
	}

	type_sym := f.table.get_type_symbol(it.typ)
	// f.write('<old name: $type_sym.name>')
	mut name := type_sym.name
	if !name.starts_with('C.') {
		name = f.no_cur_mod(f.short_module(type_sym.name)) // TODO f.type_to_str?
	}
	if name == 'void' {
		name = ''
	}
	if it.fields.len == 0 && !it.has_update_expr {
		// `Foo{}` on one line if there are no fields or comments
		if it.pre_comments.len == 0 {
			f.write('$name{}')
		} else {
			f.writeln('$name{')
			f.comments(it.pre_comments, inline: true, has_nl: true, level: .indent)
			f.write('}')
		}
		f.mark_import_as_used(name)
	} else if it.is_short {
		// `Foo{1,2,3}` (short syntax )
		f.write('$name{')
		f.mark_import_as_used(name)
		if it.has_update_expr {
			f.write('...')
			f.expr(it.update_expr)
			f.write(', ')
		}
		for i, field in it.fields {
			f.prefix_expr_cast_expr(field.expr)
			if i < it.fields.len - 1 {
				f.write(', ')
			}
		}
		f.write('}')
	} else {
		use_short_args := f.use_short_fn_args
		f.use_short_fn_args = false
		mut single_line_fields := f.single_line_fields
		f.single_line_fields = false
		if it.pos.line_nr < it.pos.last_line || it.pre_comments.len > 0 {
			single_line_fields = false
		}
		if !use_short_args {
			f.write('$name{')
			f.mark_import_as_used(name)
			if single_line_fields {
				f.write(' ')
			}
		}
		fields_start := f.out.len
		fields_loop: for {
			if !single_line_fields {
				f.writeln('')
				f.indent++
			}
			f.comments(it.pre_comments, inline: true, has_nl: true, level: .keep)
			if it.has_update_expr {
				f.write('...')
				f.expr(it.update_expr)
				f.writeln('')
				f.comments(it.update_expr_comments, inline: true, has_nl: true, level: .keep)
			}
			for i, field in it.fields {
				f.write('$field.name: ')
				f.prefix_expr_cast_expr(field.expr)
				f.comments(field.comments, inline: true, has_nl: false, level: .indent)
				if single_line_fields {
					if i < it.fields.len - 1 {
						f.write(', ')
					}
				} else {
					f.writeln('')
				}
				f.comments(field.next_comments, inline: false, has_nl: true, level: .keep)
				if single_line_fields && (field.comments.len > 0
					|| field.next_comments.len > 0
					|| !expr_is_single_line(field.expr)
					|| f.line_len > fmt.max_len.last()) {
					single_line_fields = false
					f.out.go_back_to(fields_start)
					f.line_len = fields_start
					f.remove_new_line({})
					continue fields_loop
				}
			}
			break
		}
		if !single_line_fields {
			f.indent--
		}
		if !use_short_args {
			if single_line_fields {
				f.write(' ')
			}
			f.write('}')
		}
	}
}

pub fn (mut f Fmt) const_decl(it ast.ConstDecl) {
	if it.is_pub {
		f.write('pub ')
	}
	if it.fields.len == 0 && it.pos.line_nr == it.pos.last_line {
		f.writeln('const ()\n')
		return
	}
	f.inside_const = true
	defer {
		f.inside_const = false
	}
	f.write('const ')
	if it.is_block {
		f.writeln('(')
	}
	mut max := 0
	for field in it.fields {
		if field.name.len > max {
			max = field.name.len
		}
	}
	f.indent++
	for field in it.fields {
		comments := field.comments
		mut j := 0
		for j < comments.len && comments[j].pos.pos < field.pos.pos {
			f.comment(comments[j], inline: true)
			f.writeln('')
			j++
		}
		name := field.name.after('.')
		f.write('$name ')
		f.write(strings.repeat(` `, max - field.name.len))
		f.write('= ')
		f.expr(field.expr)
		f.writeln('')
	}
	f.comments_after_last_field(it.end_comments)
	f.indent--
	if it.is_block {
		f.writeln(')\n')
	} else {
		f.writeln('')
	}
}

fn (mut f Fmt) global_decl(it ast.GlobalDecl) {
	single := it.fields.len == 1
	if single {
		f.write('__global ( ')
	} else {
		f.write('__global (')
		f.writeln('')
		f.indent++
	}
	mut max := 0
	mut has_assign := false
	for field in it.fields {
		if field.name.len > max {
			max = field.name.len
		}
		if field.has_expr {
			has_assign = true
		}
	}
	for field in it.fields {
		comments := field.comments
		for comment in comments {
			f.comment(comment, inline: true)
			f.writeln('')
		}
		f.write('$field.name ')
		f.write(strings.repeat(` `, max - field.name.len))
		if field.has_expr {
			f.write('= ')
			f.write(f.table.type_to_str(field.typ))
			f.write('(')
			f.expr(field.expr)
			f.write(')')
		} else {
			if !single && has_assign {
				f.write('  ')
			}
			f.write('${f.table.type_to_str(field.typ)} ')
		}
		if !single {
			f.writeln('')
		}
	}
	if !single {
		f.indent--
	}
	f.comments_after_last_field(it.end_comments)
	f.writeln(')\n')
}

pub fn (mut f Fmt) assign_stmt(node ast.AssignStmt) {
	f.comments(node.comments, {})
	for i, left in node.left {
		if left is ast.Ident {
			var_info := left.var_info()
			if var_info.is_static {
				f.write('static ')
			}
			f.expr(left)
		} else {
			f.expr(left)
		}
		if i < node.left.len - 1 {
			f.write(', ')
		}
	}
	f.is_assign = true
	f.write(' $node.op.str() ')
	for i, val in node.right {
		f.prefix_expr_cast_expr(val)
		if i < node.right.len - 1 {
			f.write(', ')
		}
	}
	f.comments(node.end_comments, has_nl: false, inline: true, level: .keep)
	if !f.single_line_if {
		f.writeln('')
	}
	f.is_assign = false
}

pub fn (mut f Fmt) assert_stmt(node ast.AssertStmt) {
	f.write('assert ')
	if node.expr is ast.ParExpr {
		if node.expr.expr is ast.InfixExpr {
			infix := node.expr.expr
			f.expr(infix)
			f.writeln('')
			return
		}
	}
	f.expr(node.expr)
	f.writeln('')
}

pub fn (mut f Fmt) block(node ast.Block) {
	if node.is_unsafe {
		f.write('unsafe ')
	}
	f.write('{')
	if node.stmts.len > 0 || node.pos.line_nr < node.pos.last_line {
		f.writeln('')
		f.stmts(node.stmts)
	}
	f.writeln('}')
}

pub fn (mut f Fmt) comp_for(node ast.CompFor) {
	typ := f.no_cur_mod(f.table.type_to_str(node.typ))
	f.write('\$for $node.val_var in ${typ}.$node.kind.str() {')
	if node.stmts.len > 0 || node.pos.line_nr < node.pos.last_line {
		f.writeln('')
		f.stmts(node.stmts)
	}
	f.writeln('}')
}

pub fn (mut f Fmt) defer_stmt(node ast.DeferStmt) {
	f.write('defer {')
	if node.stmts.len > 0 || node.pos.line_nr < node.pos.last_line {
		f.writeln('')
		f.stmts(node.stmts)
	}
	f.writeln('}')
}

pub fn (mut f Fmt) expr_stmt(node ast.ExprStmt) {
	f.comments(node.comments, {})
	f.expr(node.expr)
	if !f.single_line_if {
		f.writeln('')
	}
}

pub fn (mut f Fmt) for_c_stmt(node ast.ForCStmt) {
	if node.label.len > 0 {
		f.write('$node.label: ')
	}
	f.write('for ')
	if node.has_init {
		f.single_line_if = true // to keep all for ;; exprs on the same line
		f.stmt(node.init)
		f.single_line_if = false
	}
	f.write('; ')
	f.expr(node.cond)
	f.write('; ')
	f.stmt(node.inc)
	f.remove_new_line({})
	f.write(' {')
	if node.stmts.len > 0 || node.pos.line_nr < node.pos.last_line {
		f.writeln('')
		f.stmts(node.stmts)
	}
	f.writeln('}')
}

pub fn (mut f Fmt) for_in_stmt(node ast.ForInStmt) {
	if node.label.len > 0 {
		f.write('$node.label: ')
	}
	f.write('for ')
	if node.key_var != '' {
		f.write(node.key_var)
	}
	if node.val_var != '' {
		if node.key_var != '' {
			f.write(', ')
		}
		if node.val_is_mut {
			f.write('mut ')
		}
		f.write(node.val_var)
	}
	f.write(' in ')
	f.expr(node.cond)
	if node.is_range {
		f.write(' .. ')
		f.expr(node.high)
	}
	f.write(' {')
	if node.stmts.len > 0 || node.pos.line_nr < node.pos.last_line {
		f.writeln('')
		f.stmts(node.stmts)
	}
	f.writeln('}')
}

pub fn (mut f Fmt) for_stmt(node ast.ForStmt) {
	if node.label.len > 0 {
		f.write('$node.label: ')
	}
	f.write('for ')
	f.expr(node.cond)
	if !node.is_inf {
		f.write(' ')
	}
	f.write('{')
	if node.stmts.len > 0 || node.pos.line_nr < node.pos.last_line {
		f.writeln('')
		f.stmts(node.stmts)
	}
	f.writeln('}')
}

pub fn (mut f Fmt) go_stmt(node ast.GoStmt, is_expr bool) {
	f.write('go ')
	f.expr(node.call_expr)
	if !is_expr {
		f.writeln('')
	}
}

pub fn (mut f Fmt) return_stmt(node ast.Return) {
	f.comments(node.comments, {})
	f.write('return')
	if node.exprs.len > 0 {
		f.write(' ')
		// Loop over all return values. In normal returns this will only run once.
		for i, expr in node.exprs {
			f.expr(expr)
			if i < node.exprs.len - 1 {
				f.write(', ')
			}
		}
	}
	f.writeln('')
}

pub fn (mut f Fmt) sql_stmt(node ast.SqlStmt) {
	f.write('sql ')
	f.expr(node.db_expr)
	f.writeln(' {')
	table_name := util.strip_mod_name(f.table.get_type_symbol(node.table_expr.typ).name)
	f.write('\t')
	match node.kind {
		.insert {
			f.writeln('insert $node.object_var_name into $table_name')
		}
		.update {
			f.write('update $table_name set ')
			for i, col in node.updated_columns {
				f.write('$col = ')
				f.expr(node.update_exprs[i])
				if i < node.updated_columns.len - 1 {
					f.write(', ')
				} else {
					f.write(' ')
				}
				f.wrap_long_line(3, true)
			}
			f.write('where ')
			f.expr(node.where_expr)
			f.writeln('')
		}
		.delete {
			f.write('delete from $table_name where ')
			f.expr(node.where_expr)
			f.writeln('')
		}
	}
	f.writeln('}')
}
