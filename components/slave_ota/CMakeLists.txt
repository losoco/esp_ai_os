idf_component_register(
    SRCS "slave_ota.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_partition app_update freertos
    PRIV_REQUIRES log esp_hosted esp_system
)

set(SLAVE_FW_BIN "${CMAKE_CURRENT_SOURCE_DIR}/firmware/network_adapter.bin")
if(EXISTS ${SLAVE_FW_BIN})
    message(STATUS "ESP32-C5 slave firmware found: ${SLAVE_FW_BIN}")
    esptool_py_flash_to_partition(flash "slave_fw" "${SLAVE_FW_BIN}")
    # esptool validates image chip-id against the host chip (ESP32-P4), but this
    # image intentionally targets the ESP32-C5 slave and is stored in a data
    # partition. --force skips that host-side chip-id check for flash.
    set_property(TARGET flash APPEND PROPERTY SUB_ARGS "--force")
else()
    message(WARNING "ESP32-C5 slave firmware not found at ${SLAVE_FW_BIN}")
endif()
