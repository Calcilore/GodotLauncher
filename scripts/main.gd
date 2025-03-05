extends TabContainer

const SAVE_PATH: String = "user://save.json"

var choice_res: PackedScene = preload("res://scenes/choice.tscn")
@onready var choice_container: Node = %ChoiceContainer
@onready var version_option: OptionButton = %VersionOption
@onready var mono_option: OptionButton = %MonoOption
@onready var status: Label = %Status
@onready var args_edit: TextEdit = %ArgsEdit
@onready var progress_bar: ProgressBar = %ProgressBar
@onready var delete_confirmation: AcceptDialog = %DeleteConfirmation
@onready var close_on_launch_box: CheckBox = %CloseOnLaunchBox

var save: Dictionary = {}
var downloads: Dictionary = {}
var current_args_modify: Dictionary = {}
var current_download: HTTPRequest = null


func _ready():
	DirAccess.make_dir_recursive_absolute("user://versions")
	
	if FileAccess.file_exists(SAVE_PATH):
		save = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	
	_load_save()


func _load_save() -> void:
	if !save.has("versions"):
		save.versions = []
	
	# maybe i should make a proper options system
	if !save.has("options"):
		save.options = {
			"close_on_launch": true
		}
	else:
		if !save.options.has("close_on_launch"):
			save.options.close_on_launch = true
	
	close_on_launch_box.set_pressed_no_signal(save.options.close_on_launch)
	
	for child in choice_container.get_children():
		child.queue_free()
	
	save.versions.sort_custom(func(a, b): return _sort_name_change(a.name) > _sort_name_change(b.name))
	
	for version in save.versions:
		var choice: Node = choice_res.instantiate()
		choice.get_node("Name").text = version.name
		choice.get_node("OpenButton").pressed.connect(_on_open.bind(version))
		choice.get_node("UninstallButton").pressed.connect(_on_uninstall.bind(version))
		choice.get_node("ArgsButton").pressed.connect(_on_args.bind(version))
		
		choice_container.add_child(choice)


func _toggle_close_on_launch(toggled_on: bool) -> void:
	save.options.close_on_launch = !save.options.close_on_launch
	_save_save()


# makes the _mono happen after the lack of anything ones
func _sort_name_change(v_name: String) -> String:
	if v_name.ends_with("_mono"): return v_name
	return v_name + "z"


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
	
	# get command to execute
	var executable: String = '"' + ProjectSettings.globalize_path(dir.get_current_dir().path_join(file)) + '"'
	var args: String = version.args.replace("\n", " ")
	if args.contains("%command%"):
		args = args.replace("%command%", executable)
	else:
		args = executable + " " + args
	
	# make real command that is non blocking
	var command: String = "cd ~; nohup %s > %s &" % [args, ProjectSettings.globalize_path("user://log.log")]
	print("Running command: ", command)
	
	OS.execute("bash", ["-c", command])
	
	if save.options.close_on_launch:
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
	delete_confirmation.show()
	delete_confirmation.confirmed.connect(func():
		OS.execute("rm", ["-r", ProjectSettings.globalize_path("user://versions".path_join(version.name))])
		
		save.versions.erase(version)
		
		_save_save()
		_load_save()
	, CONNECT_ONE_SHOT)


func _delete_confirmation_canceled() -> void:
	for connection in delete_confirmation.confirmed.get_connections():
		delete_confirmation.confirmed.disconnect(connection.callable)


func _open_create_menu() -> void:
	current_tab = 1
	
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_recv_versions)
	
	var error = http_request.request("https://api.github.com/repos/godotengine/godot/releases")
	if error != OK:
		push_error("An error occurred in the HTTP request.")


func _open_options_menu() -> void:
	current_tab = 3


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
	if status.text != "": # if currently running
		return
	
	status.text = "Downloading godot"
	progress_bar.modulate = Color.WHITE
	progress_bar.value = 0
	
	var r_name: String = version_option.get_item_text(version_option.selected)
	var version: Dictionary = downloads[r_name]
	var mono: bool = mono_option.get_selected_id() == 1
	var download_url: String = version.mono if mono else version.stable
	
	if mono:
		r_name += "_mono"
	
	var download_dir: String = "user://versions/" + r_name
	
	DirAccess.make_dir_recursive_absolute(download_dir)
	
	current_download = HTTPRequest.new()
	add_child(current_download)
	current_download.download_file = download_dir.path_join("godot_zip.zip")
	current_download.request_completed.connect(_recv_download.bind(download_dir, r_name))
	
	var error = current_download.request(download_url)
	if error != OK:
		push_error("An error occurred in the HTTP request.")


func _recv_download(_result: int, _response_code: int, _headers: PackedStringArray, _body: PackedByteArray, \
		download_dir: String, r_name: String) -> void:
	status.text = "Extracting godot"
	progress_bar.modulate = Color.TRANSPARENT
	current_download = null
	
	get_tree().process_frame.connect(_extract_file.bind(download_dir, r_name), CONNECT_ONE_SHOT)


func _extract_file(download_dir: String, r_name: String) -> void:
	var dir: String = ProjectSettings.globalize_path(download_dir)
	OS.execute("bash", ["-c", "cd '" + dir + "';unzip godot_zip.zip"])
	DirAccess.remove_absolute(dir.path_join("godot_zip.zip"))
	
	save.versions.append({
		"name": r_name,
		"args": ""
	})
	
	_save_save()
	_load_save()
	
	status.text = ""
	current_tab = 0


func _process(delta: float) -> void:
	if current_download != null:
		progress_bar.value = float(current_download.get_downloaded_bytes()) / float(current_download.get_body_size()) * 100.0


func _on_args(version: Dictionary) -> void:
	current_args_modify = version
	args_edit.text = version.args
	current_tab = 2


func _modify_args() -> void:
	current_args_modify.args = args_edit.text
	
	_save_save()
	_load_save()
	
	current_tab = 0
