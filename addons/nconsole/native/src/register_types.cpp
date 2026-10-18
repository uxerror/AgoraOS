// Registers the NConsole's native classes with Godot.

#include "nc_cpu.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_nconsole(ModuleInitializationLevel level) {
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(NCCpuNative);
}

static void uninitialize_nconsole(ModuleInitializationLevel level) {
}

extern "C" {
GDExtensionBool GDE_EXPORT nconsole_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
		const GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
	GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
	init.register_initializer(initialize_nconsole);
	init.register_terminator(uninitialize_nconsole);
	init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}
}
