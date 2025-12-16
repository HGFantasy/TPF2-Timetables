function data()
	return {
		info = {
			description = _("mod_description_i18n"),
			name = _("mod_name_i18n"),
			minorVersion = 4,
			severityAdd = "NONE",
			severityRemove = "WARNING",
			params = { },
			tags = { "Script Mod","Script", "Timetable", "Fahrplan", "Timetables", "Fahrpläne" },
			authors = { -- OPTIONAL one or multiple authors
				{
					name = "H3lyx", -- author name
					role = "CREATOR", -- OPTIONAL "CREATOR", "CO_CREATOR", "TESTER" or "BASED_ON" or "OTHER"
					tfnetId = "" -- OPTIONAL train-fever-net author id
				},
				{
					name = "Gregory365",
					role = "BASED_ON",
					tfnetId = ""
				},
				{
					name = "Celmi",
					role = "BASED_ON",
					tfnetId = ""
				},
				{
					name = "quittung",
					role = "BASED_ON",
					tfnetId = ""
				}
			},
		},
	}
	end
