# SPDX-License-Identifier: GPL-2.0-or-later
#
# Iridia's glass cube, built and rendered from scratch in Blender (Cycles). No downloaded or
# generated art: geometry, materials and lights are all defined here.
#
#   blender -b -P Tools/branding/cube_blender.py -- <out.png> [size] [--transparent] [--samples N]
#
# Default: the cube on a dark indigo floor (app icon / launch art). --transparent renders the
# floor as a shadow catcher on a transparent background (logo mark that sits on any backdrop).

import math
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
out_path = argv[0] if argv else "/tmp/iridia_cube.png"
size = int(argv[1]) if len(argv) > 1 and argv[1].isdigit() else 1024
transparent = "--transparent" in argv
samples = int(argv[argv.index("--samples") + 1]) if "--samples" in argv else 384

INDIGO = (0.0080, 0.0045, 0.033)  # linear; ≈ sRGB #140d33


def set_input(node, names, value):
    """Principled BSDF socket names moved between Blender versions; set whichever exists."""
    for n in names if isinstance(names, (list, tuple)) else [names]:
        if n in node.inputs:
            node.inputs[n].default_value = value
            return True
    return False


# ---------------------------------------------------------------- scene
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
cy = scene.cycles
cy.samples = samples
cy.use_denoising = True
cy.max_bounces = 24
cy.transmission_bounces = 24
cy.glossy_bounces = 12
cy.caustics_reflective = True
cy.caustics_refractive = True
cy.blur_glossy = 0.0
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    cy.device = "GPU"
except Exception as e:  # CPU fallback still works, just slower
    print("GPU setup failed, using CPU:", e)

scene.render.resolution_x = size
scene.render.resolution_y = size
scene.render.film_transparent = transparent
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA" if transparent else "RGB"
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = "AgX - Medium High Contrast"

# World: a deep violet room, slightly lighter toward the horizon (reflected in the glass).
world = bpy.data.worlds.new("Room")
scene.world = world
world.use_nodes = True
wn = world.node_tree.nodes
wl = world.node_tree.links
bg = wn["Background"]
grad = wn.new("ShaderNodeTexGradient")
mapping = wn.new("ShaderNodeMapping")
coord = wn.new("ShaderNodeTexCoord")
ramp = wn.new("ShaderNodeValToRGB")
mapping.inputs["Rotation"].default_value = (0, math.radians(90), 0)
wl.new(coord.outputs["Generated"], mapping.inputs["Vector"])
wl.new(mapping.outputs["Vector"], grad.inputs["Vector"])
wl.new(grad.outputs["Fac"], ramp.inputs["Fac"])
ramp.color_ramp.elements[0].color = (0.004, 0.003, 0.016, 1)
ramp.color_ramp.elements[1].color = (0.045, 0.025, 0.12, 1)
wl.new(ramp.outputs["Color"], bg.inputs["Color"])
bg.inputs["Strength"].default_value = 1.0

# ---------------------------------------------------------------- cube
bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, 0, 0.5))
cube = bpy.context.active_object
cube.name = "IridiaCube"
cube.rotation_euler = (0, 0, math.radians(8))
bev = cube.modifiers.new("Bevel", "BEVEL")
bev.width = 0.11
bev.segments = 14
bev.profile = 0.5
bev.limit_method = "NONE"
bpy.ops.object.shade_smooth()
try:
    cube.modifiers.new("Normals", "WEIGHTED_NORMAL")
except Exception:
    pass

glass = bpy.data.materials.new("IridiaGlass")
glass.use_nodes = True
nt = glass.node_tree
p = nt.nodes["Principled BSDF"]
set_input(p, "Base Color", (0.80, 0.74, 1.0, 1))   # faint lavender tint
set_input(p, "Roughness", 0.0)
set_input(p, "IOR", 1.52)
set_input(p, ["Transmission Weight", "Transmission"], 1.0)
set_input(p, ["Specular IOR Level", "Specular"], 0.6)
# Thin-film coating: angle-dependent rainbow sheen like a soap bubble (Blender 4.2+).
set_input(p, "Thin Film Thickness", 520.0)
set_input(p, "Thin Film IOR", 1.36)
# Dispersion: the glass splits white light into colours (Blender 4.2+ Cycles).
set_input(p, "Dispersion", 1.0)
cube.data.materials.append(glass)
cube.visible_shadow = True
try:
    cube.is_caustics_caster = True
except AttributeError:
    pass

# ---------------------------------------------------------------- floor
bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, 0))
floor = bpy.context.active_object
floor.name = "Floor"
fm = bpy.data.materials.new("Floor")
fm.use_nodes = True
fp = fm.node_tree.nodes["Principled BSDF"]
set_input(fp, "Base Color", (INDIGO[0] * 0.9, INDIGO[1] * 0.9, INDIGO[2] * 0.9, 1))
set_input(fp, "Roughness", 0.22)
set_input(fp, ["Specular IOR Level", "Specular"], 0.3)
floor.data.materials.append(fm)
try:
    floor.is_caustics_receiver = True
except AttributeError:
    pass
if transparent:
    floor.is_shadow_catcher = True

# ---------------------------------------------------------------- lights
def area(name, loc, rot, size_xy, energy, color):
    bpy.ops.object.light_add(type="AREA", location=loc, rotation=rot)
    l = bpy.context.active_object
    l.name = name
    l.data.shape = "RECTANGLE"
    l.data.size, l.data.size_y = size_xy
    l.data.energy = energy
    l.data.color = color
    try:
        l.data.is_caustics_light = True
    except AttributeError:
        pass
    return l

# Key softbox top-left (the big white reflection on the top face and left edges).
area("Key", (-2.2, -1.2, 3.4), (math.radians(35), math.radians(-30), math.radians(-25)), (2.4, 1.0), 650, (1.0, 0.98, 1.0))
# Cool rim from behind-right (cyan edge line).
area("Rim", (2.4, 2.2, 1.6), (math.radians(70), math.radians(35), math.radians(135)), (0.5, 2.0), 420, (0.65, 0.85, 1.0))
# Warm low fill (pink glints on the lower bevels).
area("Fill", (-1.8, 2.4, 0.6), (math.radians(80), 0, math.radians(-140)), (1.6, 0.4), 160, (1.0, 0.7, 0.9))

# A hard spot from the upper left: refracted through the glass it throws the rainbow caustic
# onto the floor to the lower right.
bpy.ops.object.light_add(type="SPOT", location=(-3.0, -2.6, 3.8))
spot = bpy.context.active_object
spot.data.energy = 4200
spot.data.spot_size = math.radians(22)
spot.data.spot_blend = 0.3
spot.data.shadow_soft_size = 0.02
spot.data.color = (1.0, 0.97, 1.0)
try:
    spot.data.is_caustics_light = True
except AttributeError:
    pass
direction = (0 - spot.location.x, 0 - spot.location.y, 0.5 - spot.location.z)
spot.rotation_euler = (0, 0, 0)
spot.rotation_mode = "QUATERNION"
from mathutils import Vector  # noqa: E402
spot.rotation_quaternion = Vector(direction).to_track_quat("-Z", "Y")

# ---------------------------------------------------------------- camera
bpy.ops.object.camera_add(location=(2.55, -2.85, 2.35))
cam = bpy.context.active_object
cam.data.lens = 58
cam.data.dof.use_dof = True
cam.data.dof.focus_object = cube
cam.data.dof.aperture_fstop = 5.6
target = Vector((0.0, 0.0, 0.47))
cam.rotation_mode = "QUATERNION"
cam.rotation_quaternion = (target - cam.location).to_track_quat("-Z", "Y")
scene.camera = cam

scene.render.filepath = out_path
bpy.ops.render.render(write_still=True)
print("wrote", out_path, size)
