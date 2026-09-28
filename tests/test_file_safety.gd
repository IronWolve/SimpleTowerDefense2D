extends SceneTree

var checks := 0
var failures := 0

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(label)

func _initialize() -> void:
	call_deferred("run_checks")

func run_checks() -> void:
	var state := root.get_node("GameState")
	for name in ["Wave 1", "Wave 2 (3)", "camp...2", "map α"]:
		check(state.valid_data_name(name), "Valid filename rejected: " + name)
	for name in ["", ".", "..", "../escape", "a/b", "a\\b", "a:b", "a\nb", "a\tb", "a?b", "a*b", "trailing.", " leading", "CON", "nul.txt", "COM1", "LPT9", "COM¹", "LPT².txt", "CON .txt", ".hidden"]:
		check(not state.valid_data_name(name), "Unsafe filename accepted")
	# JSON represents all numbers as floats; dictionary equality is type-sensitive.
	var first := {"v": 2.0, "gold": 123.0}
	var second := {"v": 2.0, "gold": 456.0}
	check(state.write_named_save("Wave 1", first), "Initial save failed")
	check(state.read_named_save("Wave 1") == first, "Initial save did not round-trip")
	check(state.write_named_save("Wave 1", second), "Save replacement failed")
	check(state.read_named_save("Wave 1") == second, "Replacement did not round-trip")
	check(state.write_named_save("camp...2", first), "Repeated dots within a filename should work")
	check(not state.write_named_save("../escape", first), "Save escaped its directory")
	check(not state.delete_named_save("../escape"), "Delete accepted a traversal")
	check(state.read_named_save("../escape").is_empty(), "Read accepted a traversal")
	check(not FileAccess.file_exists("user://escape.json"), "Traversal created a file")
	check(state.write_save("auto", first), "Autosave failed")
	check(state.read_save("auto") == first, "Autosave did not round-trip")
	check(not state.write_save("../escape", first), "Reserved slot accepted traversal")
	check(state.save_map("map α", ["010", "000"]), "Map write failed")
	check(state.load_map_grid("map α") == ["010", "000"], "Map did not round-trip")
	check(state.load_map_grid("missing").is_empty(), "Missing map not handled")
	check(not state.save_map("../escape", ["0"]), "Map escaped its directory")
	check(not state.save_map("invalid", [123]), "Non-string map row accepted")
	var corrupt := FileAccess.open("user://saves/corrupt.json", FileAccess.WRITE)
	corrupt.store_string("{broken")
	corrupt.close()
	check(state.read_named_save("corrupt").is_empty(), "Malformed JSON was accepted")
	# A write failure must retain the existing save and report false.
	var temporary := "user://saves/Wave 1.json.tmp"
	DirAccess.make_dir_absolute(temporary)
	check(not state.write_named_save("Wave 1", first), "Blocked temporary write reported success")
	check(state.read_named_save("Wave 1") == second, "Failed write destroyed old save")
	DirAccess.remove_absolute(temporary)
	# Reading through a link must not expose a different file.
	var directory := DirAccess.open("user://")
	var destination := ProjectSettings.globalize_path("user://save_auto.json")
	check(directory.create_link(destination, "saves/link.json") == OK, "Test link creation failed")
	check(state.read_named_save("link").is_empty(), "Linked save was read")
	check(not state.write_named_save("link", second), "Linked save was overwritten")
	check(state.read_save("auto") == first, "Link target was changed")
	check(not state.delete_named_save("link"), "Linked save was deleted")
	check("link" not in state.list_saves(), "Linked save was listed")
	directory.remove("saves/link.json")
	# Oversized files are rejected before decoding JSON.
	var big := FileAccess.open("user://saves/large.json", FileAccess.WRITE)
	big.seek(state.MAX_DATA_FILE_BYTES)
	big.store_8(0)
	big.close()
	check(state.read_named_save("large").is_empty(), "Oversized save was accepted")
	check(state.delete_named_save("large"), "Test oversized save could not be removed")
	check(state.delete_named_save("Wave 1"), "Existing save deletion failed")
	check(not state.delete_named_save("Wave 1"), "Missing save deletion reported success")
	print("File-safety checks: %d passed, %d failed" % [checks - failures, failures])
	quit(1 if failures else 0)
