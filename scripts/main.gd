extends TabContainer

const SAVE_PATH: String = "user://save.json"

var choice_res: PackedScene = preload("res://scenes/choice.tscn")
@onready var choice_container: Node = %ChoiceContainer
@onready var version_option: OptionButton = %VersionOption
@onready var mono_option: OptionButton = %MonoOption
@onready var status: Label = %Status
@onready var args_edit: TextEdit = %ArgsEdit

var save: Dictionary = {}
var downloads: Dictionary = {}
var current_args_modify: Dictionary = {}


func _ready():
	DirAccess.make_dir_recursive_absolute("user://versions")
	
	if FileAccess.file_exists(SAVE_PATH):
		save = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	
	_load_save()


func _load_save() -> void:
	if !save.has("versions"):
		save.versions = []
	
	for child in choice_container.get_children():
		child.queue_free()
	
	for version in save.versions:
		var choice: Node = choice_res.instantiate()
		choice.get_node("Name").text = version.name
		choice.get_node("OpenButton").pressed.connect(_on_open.bind(version))
		choice.get_node("UninstallButton").pressed.connect(_on_uninstall.bind(version))
		choice.get_node("ArgsButton").pressed.connect(_on_args.bind(version))
		
		choice_container.add_child(choice)


func _save_save() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(save))
	file.close()


func _on_open(version: Dictionary) -> void:
	var dir = DirAccess.open("user://versions/" + version.name)
	if dir == null:
		print("An error occurred when trying to access the path.")
		return
	
	var file: String = _search_path(dir, func(file_name: String):
		return file_name.ends_with(".x86_64") or file_name.ends_with(".64")
	)
	
	var executable: String = ProjectSettings.globalize_path(dir.get_current_dir().path_join(file))
	var args: String = version.args.replace("\n", " ")
	if args.contains("%command%"):
		args = args.replace("%command%", executable)
	else:
		args = executable + " " + args
	
	print("Running command: " + args)
	
	OS.execute_with_pipe("bash", ["-c", "cd ~;" + args])
	
	get_tree().quit(0)


func _search_path(dir: DirAccess, on_file: Callable, previous: String = "") -> String:
	if dir == null:
		print("An error occurred when trying to access the path.")
		return ""
	
	var dirs: Array = []
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if dir.current_is_dir():
			dirs.append(file_name)
		else:
			if on_file.call(previous.path_join(file_name)):
				return previous.path_join(file_name)
		
		file_name = dir.get_next()
	
	for other in dirs:
		var new_path = previous.path_join(other)
		print("opening ", new_path)
		var new_dir = DirAccess.open(dir.get_current_dir().path_join(new_path))
		var result = _search_path(new_dir, on_file, new_path)
		if result != "//":
			return result
	
	return "//"



func _on_uninstall(version: Dictionary) -> void:
	OS.execute("rm", ["-r", ProjectSettings.globalize_path("user://versions".path_join(version.name))])
	
	save.versions.erase(version)
	
	_save_save()
	_load_save()


func _open_create_menu() -> void:
	current_tab = 1
	
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_recv_versions)
	
	var error = http_request.request("https://api.github.com/repos/godotengine/godot/releases")
	if error != OK:
		push_error("An error occurred in the HTTP request.")


func _recv_versions(_result: int, _response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var json: Array = JSON.parse_string(body.get_string_from_utf8())
	
	for release: Dictionary in json:
		var r_name: String = release.tag_name
		var stable_download = null
		var mono_download = null
		
		for asset: Dictionary in release.assets:
			if asset.name.contains("linux.x86_64") or asset.name.contains("linux_x86_64") or \
					asset.name.contains("x11.64") or asset.name.contains("x11_64"):
				if asset.name.contains("mono"):
					mono_download = asset.browser_download_url
				else:
					stable_download = asset.browser_download_url
		
		downloads[r_name] = {
			"name": r_name,
			"stable": stable_download,
			"mono": mono_download
		}
	
	# Add versions to options but sorted
	version_option.clear()
	
	var downs: Array = downloads.values()
	downs.sort_custom(func(a, b): return a.name > b.name)
	
	for down in downs:
		version_option.add_item(down.name)


func _create_version() -> void:
	status.text = "downloading godot"
	
	var r_name: String = version_option.get_item_text(version_option.selected)
	var version: Dictionary = downloads[r_name]
	var mono: bool = mono_option.get_selected_id() == 1
	var download_url: String = version.mono if mono else version.stable
	
	if mono:
		r_name += "_mono"
	
	var download_dir: String = "user://versions/" + r_name
	
	DirAccess.make_dir_recursive_absolute(download_dir)
	
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.download_file = download_dir.path_join("godot_zip.zip")
	http_request.request_completed.connect(_recv_download.bind(download_dir, r_name))
	
	var error = http_request.request(download_url)
	if error != OK:
		push_error("An error occurred in the HTTP request.")


func _recv_download(_result: int, _response_code: int, _headers: PackedStringArray, _body: PackedByteArray, \
		download_dir: String, r_name: String) -> void:
	status.text = "extracting godot"
	
	get_tree().process_frame.connect(_extract_file.bind(download_dir, r_name), CONNECT_ONE_SHOT)


func _extract_file(download_dir: String, r_name: String) -> void:
	var dir: String = ProjectSettings.globalize_path(download_dir)
	OS.execute("bash", ["-c", "cd " + dir + ";unzip godot_zip.zip"])
	DirAccess.remove_absolute(dir.path_join("godot_zip.zip"))
	
	save.versions.append({
		"name": r_name,
		"args": ""
	})
	
	_save_save()
	_load_save()
	
	status.text = "done"


func _on_args(version: Dictionary) -> void:
	current_args_modify = version
	args_edit.text = version.args
	current_tab = 2


func _modify_args() -> void:
	current_args_modify.args = args_edit.text
	
	_save_save()
	_load_save()
	
	current_tab = 0
