# OV7670 SCCB electrical aid: enable weak internal pullups on the current
# IO3 (SCL=T11) and IO2 (SDA=P14) pins. Pin locations remain unchanged.
# External ~2.2k..4.7k pullups to 3.3V are more reliable for real cabling.
set_property PULLUP true [get_ports {scl sda}]
