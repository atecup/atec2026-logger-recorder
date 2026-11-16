# Robot overall operating modes.
uint8 STOPPED=0
uint8 AUTONOMY=1
uint8 MOTION_TELEOP=2
uint8 MANIPULATION_TELEOP=3

std_msgs/Header header
uint64 sequence
# Overall operating mode: 0-3 have fixed meanings; 4-255 are team-defined.
# Document additional mode values in adapter/data_description.md.
uint8 state

# Extensible robot status quantities, including effective modes/function states
# associated with physical buttons/switches.
# Report effective robot states, not raw button values.
# Names must be unique and correspond one-to-one with values.
# Document each name and value meaning in adapter/data_description.md.
string[] status_names
float64[] status_values
