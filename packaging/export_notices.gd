extends SceneTree

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("Expected a destination for third-party notices")
		quit(1)
		return
	var file := FileAccess.open(args[0], FileAccess.WRITE)
	if file == null:
		push_error("Unable to create third-party notices")
		quit(1)
		return
	file.store_string(LicenseNotices.text())
	file.flush()
	var result := file.get_error()
	file.close()
	quit(0 if result == OK else 1)
