data:extend({
  {
    type = "int-setting",
    name = "alina-sensor-radius",
    setting_type = "runtime-global",
    default_value = 64,
    minimum_value = 16,
    maximum_value = 192,
    order = "a"
  },
  {
    type = "int-setting",
    name = "alina-resource-scan-limit",
    setting_type = "runtime-global",
    default_value = 256,
    minimum_value = 32,
    maximum_value = 1024,
    order = "b"
  },
  {
    type = "int-setting",
    name = "alina-player-active-seconds",
    setting_type = "runtime-global",
    default_value = 30,
    minimum_value = 5,
    maximum_value = 300,
    order = "c"
  },
  {
    type = "bool-setting",
    name = "alina-auto-spawn",
    setting_type = "runtime-global",
    default_value = true,
    order = "d"
  },
  {
    type = "bool-setting",
    name = "alina-autonomy-enabled",
    setting_type = "runtime-global",
    default_value = true,
    order = "e"
  },
  {
    type = "int-setting",
    name = "alina-autonomy-interval-seconds",
    setting_type = "runtime-global",
    default_value = 180,
    minimum_value = 30,
    maximum_value = 1800,
    order = "f"
  },
  {
    type = "int-setting",
    name = "alina-bridge-udp-port",
    setting_type = "runtime-global",
    default_value = 34198,
    minimum_value = 1024,
    maximum_value = 65535,
    order = "g"
  },
  {
    type = "int-setting",
    name = "alina-world-model-radius",
    setting_type = "runtime-global",
    default_value = 384,
    minimum_value = 128,
    maximum_value = 1024,
    order = "h"
  },
  {
    type = "string-setting",
    name = "alina-display-name",
    setting_type = "runtime-global",
    default_value = "Алина",
    allow_blank = false,
    order = "j"
  },
  {
    type = "string-setting",
    name = "alina-address-aliases",
    setting_type = "runtime-global",
    default_value = "Алина, Аля, Алечка, Алиночка, Алинка",
    allow_blank = true,
    order = "k"
  },
  {
    type = "string-setting",
    name = "alina-praise-frequency",
    setting_type = "runtime-global",
    default_value = "rare",
    allowed_values = {"off", "rare", "normal"},
    order = "l"
  },
  {
    type = "bool-setting",
    name = "alina-periodic-advice-enabled",
    setting_type = "runtime-global",
    default_value = true,
    order = "m"
  },
  {
    type = "string-setting",
    name = "alina-ui-verbosity",
    setting_type = "runtime-global",
    default_value = "compact",
    allowed_values = {"compact", "normal", "debug"},
    order = "n"
  }
})
