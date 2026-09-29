class_name LicenseNotices
extends RefCounted

static func text() -> String:
	var lines := PackedStringArray(["Godot Engine", Engine.get_license_text(), "Third-party component notices"])
	for component in Engine.get_copyright_info():
		lines.append("\n" + str(component["name"]))
		for part in component["parts"]:
			for copyright in part["copyright"]:
				lines.append(str(copyright))
			lines.append("License: " + str(part["license"]))
	var licenses := Engine.get_license_info()
	var names := licenses.keys()
	names.sort()
	for name in names:
		lines.append("\n" + str(name) + "\n" + str(licenses[name]))
	return "\n".join(lines) + "\n"
