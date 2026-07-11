/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#pragma once

#define QMC6309_I2C_ADDR                0x7C
#define QMC6309_CHIP_ID                 0x90

#define QMC6309_REG_CHIP_ID             0x00
#define QMC6309_REG_DATA_X_LSB          0x01
#define QMC6309_REG_STATUS              0x09
#define QMC6309_REG_CTRL1               0x0A
#define QMC6309_REG_CTRL2               0x0B

#define QMC6309_CTRL2_SOFT_RESET        0x80
#define QMC6309_CTRL1_CONT_MODE         0x63

/* OSR=11 (bits 7:6), RNG=01 (bits 5:4), MODE bits 1:0 */
#define QMC6309_CTRL1_OSR_RNG           0xD0
#define QMC6309_CTRL1_MODE_SUSPEND      0x00
#define QMC6309_CTRL1_MODE_NORMAL       0x01
#define QMC6309_CTRL1_MODE_CONTINUOUS   0x03

#define QMC6309_CTRL2_SET_RESET         0x03

#define QMC6309_STATUS_DATA_READY       0x01
