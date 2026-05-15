package wodin

import "core:fmt"
import "core:net"
import "core:os"
import "core:odin/ast"
import "core:odin/parser"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

Build_Config :: struct {
	src_dir:          string,
	out_dir:          string,
	template_path:    string, // Empty string signals use of DEFAULT_TEMPLATE
	app_name:         string,
	port:             int,
	extra_build_args: []string, // Everything after -- on the command line
}

Js_Binding_Lib :: struct {
	import_name: string,
	functions:   [dynamic]Js_Function,
	variables:   [dynamic]Js_Variable,
}

Js_Function :: struct {
	name:    string,
	params:  string,
	js_body: string,
}

Js_Variable :: struct {
	name:  string,
	value: string,
}

INJECTION_MARKER :: "<!-- WODIN_BINDINGS -->"
NAME_MARKER      :: "<!-- WODIN_NAME -->"

DEFAULT_TEMPLATE :: `<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title><!-- WODIN_NAME --></title>
</head>
<body>
    <!-- WODIN_BINDINGS -->
</body>
</html>
`

main :: proc() {
	if len(os.args) < 2 {
		print_usage()
		os.exit(1)
	}

	cmd := os.args[1]
	cfg: Build_Config
	cfg.src_dir = "."
	cfg.out_dir = "out"
	cfg.port = 8080

	args := os.args[2:]
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--" {
			cfg.extra_build_args = args[i+1:]
			break
		}
		if strings.has_prefix(arg, "-out:")          do cfg.out_dir = arg[5:]
		else if strings.has_prefix(arg, "-template:") do cfg.template_path = arg[10:]
		else if strings.has_prefix(arg, "-port:") {
			if p, ok := strconv.parse_int(arg[6:]); ok do cfg.port = p
		} else do cfg.src_dir = arg
	}

	switch cmd {
	case "build":
		if !run_build(cfg) do os.exit(1)
	case "run":
		if run_build(cfg) {
			serve(cfg.out_dir, cfg.port)
		}
	case "help", "--help", "-h":
		print_usage()
	case:
		fmt.eprintfln("wodin: unknown command '%s'", cmd)
		os.exit(1)
	}
}

print_usage :: proc() {
	fmt.println("usage: wodin <build|run> <dir> [-template:<file>] [-out:<dir>] [-port:<n>] [-- <odin flags>]")
	fmt.println("\nTags (inside foreign blocks):")
	fmt.println("  @(tag=`wodin.function { return a + b }`)")
	fmt.println("  @(tag=`wodin.variable`)")
	fmt.println("  @(tag=`wodin.variable = 42`)")
	fmt.println("\nAny flags after -- are passed directly to the odin build command:")
	fmt.println("  wodin build myapp -- -debug -vet -warnings-as-errors")
}

run_build :: proc(cfg: Build_Config) -> bool {
	cfg := cfg
	abs_src, _ := filepath.abs(cfg.src_dir, context.temp_allocator)
	cfg.app_name = filepath.base(abs_src)

	fmt.printfln("wodin: building %s...", cfg.app_name)

	os.remove_all(cfg.out_dir)
	os.make_directory(cfg.out_dir)

	libs := collect_bindings(abs_src)
	defer {
		for l in libs {
			delete(l.import_name)
			for f in l.functions { delete(f.name); delete(f.params); delete(f.js_body) }
			for v in l.variables { delete(v.name); delete(v.value) }
			delete(l.functions); delete(l.variables)
		}
		delete(libs)
	}

	wasm_filename := strings.concatenate({cfg.app_name, ".wasm"}, context.temp_allocator)
	wasm_out, _ := filepath.join({cfg.out_dir, wasm_filename}, context.temp_allocator)
	out_flag := strings.concatenate({"-out:", wasm_out}, context.temp_allocator)
	
	base_cmd := []string{"odin", "build", abs_src, "-target:js_wasm32", out_flag}
	build_cmd := make([]string, len(base_cmd) + len(cfg.extra_build_args), context.temp_allocator)
	copy(build_cmd, base_cmd)
	copy(build_cmd[len(base_cmd):], cfg.extra_build_args)
	if !run_command(build_cmd) do return false

	odin_js_src, found := find_odin_js()
	if !found {
		fmt.eprintln("wodin: error: cannot find odin.js")
		return false
	}
	defer delete(odin_js_src)

	odin_js_dst, _ := filepath.join({cfg.out_dir, "odin.js"}, context.temp_allocator)
	copy_file(odin_js_src, odin_js_dst)

	return generate_index_html(cfg, libs[:])
}

// extract_proc_type pulls an ast.Proc_Type out of whatever node a foreign proc
// declaration puts the signature on.
//
// For a regular `name :: proc(...) -> T {}` the proc type is inside a Proc_Lit
// stored in vd.values[0].  For a foreign `name :: proc(...) -> T ---` the
// parser emits NO values at all; the proc type sits directly on vd.type.
// We handle both so the same helper works everywhere.
extract_proc_type :: proc(vd: ^ast.Value_Decl) -> (^ast.Proc_Type, bool) {
	// Case 1: foreign proc — type is on vd.type directly (most common for us).
	if vd.type != nil {
		if pt, ok := vd.type.derived.(^ast.Proc_Type); ok {
			return pt, true
		}
	}

	// Case 2: regular proc lit — type is wrapped inside vd.values[0].
	if len(vd.values) > 0 {
		// Unwrap Proc_Lit first, then read its type field.
		if pl, ok := vd.values[0].derived.(^ast.Proc_Lit); ok {
			if pl.type != nil {
				if pt, ok2 := pl.type.derived.(^ast.Proc_Type); ok2 {
					return pt, true
				}
			}
		}
		// Bare Proc_Type (shouldn't happen in practice, but be defensive).
		if pt, ok := vd.values[0].derived.(^ast.Proc_Type); ok {
			return pt, true
		}
	}

	return nil, false
}

// build_params_string turns a proc's parameter field list into a
// comma-separated JS parameter string, e.g. "a, b, c".
build_params_string :: proc(proc_type: ^ast.Proc_Type, allocator := context.allocator) -> string {
	if proc_type.params == nil || len(proc_type.params.list) == 0 {
		return strings.clone("", allocator)
	}

	sb := strings.builder_make(context.temp_allocator)
	first := true
	for field in proc_type.params.list {
		for p_name_expr in field.names {
			if p_ident, ok := p_name_expr.derived.(^ast.Ident); ok {
				if !first do strings.write_string(&sb, ", ")
				strings.write_string(&sb, p_ident.name)
				first = false
			}
		}
	}
	return strings.clone(strings.to_string(sb), allocator)
}

collect_bindings :: proc(dir: string) -> [dynamic]Js_Binding_Lib {
	libs := make([dynamic]Js_Binding_Lib)
	
	get_lib :: proc(libs: ^[dynamic]Js_Binding_Lib, name: string) -> ^Js_Binding_Lib {
		for &l in libs { if l.import_name == name do return &l }
		append(libs, Js_Binding_Lib{import_name = strings.clone(name)})
		return &libs[len(libs)-1]
	}

	fd, err := os.open(dir)
	if err != os.ERROR_NONE do return libs
	defer os.close(fd)

	infos, _ := os.read_dir(fd, -1, context.temp_allocator)
	for info in infos {
		if info.type == .Directory && info.name[0] != '.' && info.name != "out" {
			sub := collect_bindings(info.fullpath)
			for sl in sub do append(&libs, sl)
		} else if strings.has_suffix(info.name, ".odin") {
			p: parser.Parser
			f := ast.File{fullpath = info.fullpath}
			data, read_ok := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
			if read_ok != os.General_Error.None do continue
			f.src = string(data)
			parser.parse_file(&p, &f)

			for decl in f.decls {
				fb, fb_ok := decl.derived.(^ast.Foreign_Block_Decl)
				if !fb_ok do continue
				
				// Resolve the Odin-side import identifier to use as the JS
				// namespace key.  The string matches the foreign import alias,
				// which in turn matches the WebAssembly import namespace that
				// odin.js uses when calling WebAssembly.instantiateStreaming.
				lib_name: string
				if ident, i_ok := fb.foreign_library.derived.(^ast.Ident); i_ok {
					lib_name = ident.name
				}

				target := get_lib(&libs, lib_name)
				block, b_ok := fb.body.derived.(^ast.Block_Stmt)
				if !b_ok do continue

				for stmt in block.stmts {
					vd, v_ok := stmt.derived.(^ast.Value_Decl)
					if !v_ok || len(vd.attributes) == 0 do continue

					// Pull the proc name from the declaration's LHS.
					name := vd.names[0].derived.(^ast.Ident).name

					// FIX (Bug 1): foreign procs have NO values; the proc type
					// is on vd.type, not vd.values[0].  Use the helper which
					// handles both foreign and non-foreign procs correctly.
					params_str := ""
					if proc_type, ok := extract_proc_type(vd); ok {
						params_str = build_params_string(proc_type, context.temp_allocator)
					}

					for attr in vd.attributes {
						for elem in attr.elems {
							fv, f_ok := elem.derived.(^ast.Field_Value)
							if !f_ok do continue

							raw := f.src[fv.value.pos.offset:fv.value.end.offset]
							tag := strings.trim(raw, "`\"")

							if strings.has_prefix(tag, "wodin.function") {
								s_idx := strings.index_byte(tag, '{')
								e_idx := strings.last_index_byte(tag, '}')
								if s_idx != -1 && e_idx != -1 {
									body := strings.trim_space(tag[s_idx+1 : e_idx])
									append(&target.functions, Js_Function{
										name    = strings.clone(name),
										js_body = strings.clone(body),
										params  = strings.clone(params_str),
									})
								}
							} else if strings.has_prefix(tag, "wodin.variable") {
								// Supports both bare `wodin.variable` and
								// `wodin.variable = <expr>`.
								val := ""
								if idx := strings.index_byte(tag, '='); idx != -1 {
									val = strings.trim_space(tag[idx+1:])
								}
								append(&target.variables, Js_Variable{
									name  = strings.clone(name),
									value = strings.clone(val),
								})
							}
						}
					}
				}
			}
		}
	}
	return libs
}

generate_index_html :: proc(cfg: Build_Config, libs: []Js_Binding_Lib) -> bool {
	s_tpl: string
	if cfg.template_path != "" {
		tpl, ok := os.read_entire_file_from_path(cfg.template_path, context.temp_allocator)
		if ok != os.General_Error.None {
			fmt.eprintln("wodin: error: template not found")
			return false
		}
		s_tpl = string(tpl)
	} else {
		s_tpl = DEFAULT_TEMPLATE
	}
	
	if !strings.contains(s_tpl, INJECTION_MARKER) {
		fmt.eprintln("wodin: error: marker missing in template")
		return false
	}

	// Two-pass codegen:
	//
	// Pass 1 — emit `let` declarations for every wodin.variable, collected
	// across all libs.  These sit at the top of the script block so that the
	// arrow functions defined in _wodin below can close over them.
	//
	//   let val;        // bare wodin.variable
	//   let val = 42;   // wodin.variable = 42
	//
	// They are intentionally NOT added to the _wodin import object — WASM can
	// only import functions/memories/tables/globals, not plain JS values.
	// The convention is that Odin-side getters/setters (tagged wodin.function)
	// read and write these slots; the foreign variable declaration is just an
	// annotation marking the JS variable's existence.
	//
	// Pass 2 — emit the _wodin import object containing only functions.

	sb := strings.builder_make(context.temp_allocator)

	// Everything Odin-related is injected at the marker — authors need no
	// knowledge of the Odin runtime to write a compatible template.

	// Error display element.
	strings.write_string(&sb, "<div id=\"wodin-error\" style=\"display:none;color:red;font-family:monospace;padding:1em;white-space:pre-wrap;\"></div>\n")

	// Odin JS runtime.
	strings.write_string(&sb, "<script src=\"odin.js\"></script>\n")

	// Bindings script: let declarations then the _wodin import object.
	strings.write_string(&sb, "<script>\n")

	// Pass 1: let declarations
	for lib in libs {
		for v in lib.variables {
			strings.write_string(&sb, "  let ")
			strings.write_string(&sb, v.name)
			if v.value != "" {
				strings.write_string(&sb, " = ")
				strings.write_string(&sb, v.value)
			}
			strings.write_string(&sb, ";\n")
		}
	}

	// Pass 2: _wodin import object (functions only, libs with no functions omitted)
	strings.write_string(&sb, "  var _wodin = {\n")
	for lib in libs {
		if len(lib.functions) == 0 do continue
		strings.write_string(&sb, "    \"")
		strings.write_string(&sb, lib.import_name)
		strings.write_string(&sb, "\": {\n")

		for f in lib.functions {
			// NOTE: never use fmt.sbprintf for JS bodies — braces in the body
			// string are misinterpreted as format directives.
			strings.write_string(&sb, "      ")
			strings.write_string(&sb, f.name)
			strings.write_string(&sb, ": (")
			strings.write_string(&sb, f.params)
			strings.write_string(&sb, ") => {")
			strings.write_string(&sb, f.js_body)
			strings.write_string(&sb, "},\n")
		}

		strings.write_string(&sb, "    },\n")
	}
	strings.write_string(&sb, "  };\n")
	strings.write_string(&sb, "</script>\n")

	// WASM bootstrap module.
	strings.write_string(&sb, "<script type=\"module\">\n")
	strings.write_string(&sb, "  const wmi = new odin.WasmMemoryInterface();\n")
	strings.write_string(&sb, "  try {\n")
	strings.write_string(&sb, "    await odin.runWasm(\"")
	strings.write_string(&sb, cfg.app_name)
	strings.write_string(&sb, ".wasm\", null, _wodin, wmi);\n")
	strings.write_string(&sb, "  } catch (e) {\n")
	strings.write_string(&sb, "    const el = document.getElementById(\"wodin-error\");\n")
	strings.write_string(&sb, "    if (el) { el.style.display = \"block\"; el.textContent = String(e); }\n")
	strings.write_string(&sb, "    throw e;\n")
	strings.write_string(&sb, "  }\n")
	strings.write_string(&sb, "</script>")
	
	with_bindings, _ := strings.replace(s_tpl, INJECTION_MARKER, strings.to_string(sb), 1, context.temp_allocator)
	output, _         := strings.replace(with_bindings, NAME_MARKER, cfg.app_name, -1, context.temp_allocator)
	out_path, _ := filepath.join({cfg.out_dir, "index.html"}, context.temp_allocator)
	write_err := os.write_entire_file(out_path, transmute([]byte)output)
	
	return write_err == os.ERROR_NONE
}

// serve starts a minimal blocking HTTP/1.1 file server rooted at `dir`.
// It handles one request at a time (sufficient for local dev use).
// Serves index.html for "/" and any other path directly from the out dir.
// Returns only on a fatal listen/accept error.
serve :: proc(dir: string, port: int) {
	addr := net.IP4_Address{0, 0, 0, 0}
	endpoint := net.Endpoint{address = net.Address(addr), port = port}

	sock, err := net.listen_tcp(endpoint)
	if err != nil {
		fmt.eprintfln("wodin: cannot listen on port %d: %v", port, err)
		return
	}
	defer net.close(sock)

	fmt.printfln("wodin: serving on http://localhost:%d  (Ctrl-C to stop)", port)

	for {
		client, _, accept_err := net.accept_tcp(sock)
		if accept_err != nil do continue
		handle_request(client, dir)
		net.close(client)
	}
}

// mime_type_for returns a Content-Type string for common static extensions.
mime_type_for :: proc(path: string) -> string {
	if strings.has_suffix(path, ".html") do return "text/html; charset=utf-8"
	if strings.has_suffix(path, ".js")   do return "application/javascript"
	if strings.has_suffix(path, ".wasm") do return "application/wasm"
	if strings.has_suffix(path, ".css")  do return "text/css"
	if strings.has_suffix(path, ".png")  do return "image/png"
	if strings.has_suffix(path, ".jpg")  do return "image/jpeg"
	if strings.has_suffix(path, ".svg")  do return "image/svg+xml"
	return "application/octet-stream"
}

// handle_request reads one HTTP request from `client` and writes a response.
handle_request :: proc(client: net.TCP_Socket, dir: string) {
	// Read until we have the request line — we only need the first line.
	buf: [4096]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	if recv_err != nil || n == 0 do return

	req := string(buf[:n])
	// Request line is "METHOD /path HTTP/1.x\r\n..."
	line_end := strings.index_byte(req, '\n')
	if line_end < 0 do line_end = n
	parts := strings.fields(req[:line_end], context.temp_allocator)
	if len(parts) < 2 do return

	url_path := parts[1]

	// Strip query string.
	if qi := strings.index_byte(url_path, '?'); qi >= 0 {
		url_path = url_path[:qi]
	}

	// Map "/" → "/index.html".
	if url_path == "/" do url_path = "/index.html"

	// Build filesystem path — strip the leading slash, join with out dir.
	rel := url_path[1:]
	file_path, _ := filepath.join({dir, rel}, context.temp_allocator)

	body, read_ok := os.read_entire_file_from_path(file_path, context.temp_allocator)

	sb := strings.builder_make(context.temp_allocator)
	if read_ok != os.General_Error.None {
		strings.write_string(&sb, "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found")
	} else {
		mime := mime_type_for(file_path)
		strings.write_string(&sb, "HTTP/1.1 200 OK\r\n")
		strings.write_string(&sb, "Content-Type: ")
		strings.write_string(&sb, mime)
		strings.write_string(&sb, "\r\n")
		// Required for SharedArrayBuffer / WASM threads if ever needed.
		strings.write_string(&sb, "Cross-Origin-Opener-Policy: same-origin\r\n")
		strings.write_string(&sb, "Cross-Origin-Embedder-Policy: require-corp\r\n")
		fmt.sbprintf(&sb, "Content-Length: %d\r\n\r\n", len(body))

		header := strings.to_string(sb)
		net.send_tcp(client, transmute([]byte)header)
		net.send_tcp(client, body)
		return
	}

	response := strings.to_string(sb)
	net.send_tcp(client, transmute([]byte)response)
}

run_command :: proc(args: []string) -> bool {
	p, _ := os.process_start(os.Process_Desc{command = args, stdout = os.stdout, stderr = os.stderr})
	state, _ := os.process_wait(p)
	return state.exit_code == 0
}

copy_file :: proc(src, dst: string) {
	d, ok := os.read_entire_file_from_path(src, context.temp_allocator)
	if ok == os.General_Error.None {
		_ = os.write_entire_file(dst, d)
	}
}

capture_command_output :: proc(args: []string) -> (string, bool) {
	desc := os.Process_Desc{command = args}
	state, stdout, _stderr, err := os.process_exec(desc, context.temp_allocator)
	if err != nil || state.exit_code != 0 do return "", false
	trimmed := strings.trim_space(string(stdout))
	if trimmed == "" do return "", false
	return strings.clone(trimmed), true
}

find_odin_js :: proc() -> (string, bool) {
	root: string
	root_found := false

	if output, ok := capture_command_output({"odin", "root"}); ok {
		root = output
		root_found = true
	}

	if !root_found {
		if env_root, ok := os.lookup_env("ODIN_ROOT", context.temp_allocator); ok {
			root = env_root
			root_found = true
		}
	}

	if !root_found do return "", false

	paths := [?]string{
		"vendor/wasm/js/odin.js",
		"core/sys/wasm/js/odin.js",
	}

	for p in paths {
		full_path, _ := filepath.join({root, p}, context.temp_allocator)
		if os.exists(full_path) {
			return strings.clone(full_path), true
		}
	}

	return "", false
}
