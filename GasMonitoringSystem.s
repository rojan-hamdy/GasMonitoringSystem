; ============================================================
;  COMBINED: DHT11 (Temp/Humidity) + MQ135 (Gas) — STM32F4 @ 16 MHz displaying on traffic light module
;
;  HARDWARE MAP
;  +-----------------------------------------------------------------+
;  | PA0      | MQ135 analog output  (ADC1 Channel 0)               |
;  | PA1      | DHT11 data           (open-drain + internal pull-up) |
;  | PB0      | RED    LED  — SEVERE                                 |
;  | PB1      | YELLOW LED  — MODERATE                               |
;  | PB2      | GREEN  LED  — SAFE                                   |
;  | TIM2     | Free-running 1 MHz counter (µs DHT11 timing)         |
;  | ADC1     | Continuous mode on CH0 for MQ135                     |
;  +-----------------------------------------------------------------+
;
;  SEVERITY LOGIC
;  - DHT11 evaluates temperature + humidity  => dht_severity
;  - MQ135 evaluates gas level (w/ hysteresis) => gas_severity
;  - final_severity = MAX(dht_severity, gas_severity)
;  - LEDs reflect final_severity only
; ============================================================

        AREA    |.text|, CODE, READONLY
        EXPORT  __main

; -------------------------------------------------------------
;  PERIPHERAL BASE ADDRESSES
; -------------------------------------------------------------
RCC_BASE        EQU     0x40023800
GPIOA_BASE      EQU     0x40020000
GPIOB_BASE      EQU     0x40020400
TIM2_BASE       EQU     0x40000000
ADC1_BASE       EQU     0x40012000

; --- RCC Offsets ---
RCC_AHB1ENR     EQU     0x30        ; GPIOA | GPIOB
RCC_APB1ENR     EQU     0x40        ; TIM2
RCC_APB2ENR     EQU     0x44        ; ADC1

; --- GPIO Offsets ---
GPIO_MODER      EQU     0x00
GPIO_OTYPER     EQU     0x04
GPIO_OSPEEDR    EQU     0x08
GPIO_PUPDR      EQU     0x0C
GPIO_IDR        EQU     0x10
GPIO_BSRR       EQU     0x18

; --- TIM2 Offsets ---
TIM_CR1         EQU     0x00
TIM_EGR         EQU     0x14
TIM_CNT         EQU     0x24
TIM_PSC         EQU     0x28
TIM_ARR         EQU     0x2C

; --- ADC1 Offsets ---
ADC_SR          EQU     0x00
ADC_CR2         EQU     0x08
ADC_SMPR2       EQU     0x10
ADC_SQR3        EQU     0x34
ADC_DR          EQU     0x4C

; -------------------------------------------------------------
;  PIN MASKS
; -------------------------------------------------------------
DHT11_MASK      EQU     (1 << 1)    ; PA1
RED_PIN         EQU     (1 << 0)    ; PB0
YELLOW_PIN      EQU     (1 << 1)    ; PB1
GREEN_PIN       EQU     (1 << 2)    ; PB2
ALL_LEDS        EQU     (RED_PIN | YELLOW_PIN | GREEN_PIN)

; -------------------------------------------------------------
;  SEVERITY LEVELS (shared by both sensors)
; -------------------------------------------------------------
SEV_SAFE        EQU     0
SEV_MODERATE    EQU     1
SEV_SEVERE      EQU     2

; -------------------------------------------------------------
;  DHT11 THRESHOLDS
; -------------------------------------------------------------
T_SEVERE_HI     EQU     35          ; >35 °C  -> SEVERE
T_MODERATE_HI   EQU     28          ; >28 °C  -> MODERATE
T_MODERATE_LO   EQU     18          ; <18 °C  -> MODERATE
T_SEVERE_LO     EQU     10          ; <10 °C  -> SEVERE

H_SEVERE_HI     EQU     75          ; >75 %   -> SEVERE
H_MODERATE_HI   EQU     60          ; >60 %   -> MODERATE
H_MODERATE_LO   EQU     30          ; <30 %   -> MODERATE
H_SEVERE_LO     EQU     20          ; <20 %   -> SEVERE

; --- DHT11 Protocol Timing ---
DHT_START_LOW   EQU     18000       ; Host holds LOW for 18 ms
DHT_START_HIGH  EQU     40          ; Host releases HIGH for 40 µs
DHT_RESP_TOUT   EQU     100         ; Ack / bit-phase timeout (µs)
DHT_BIT_SAMPLE  EQU     40          ; Sample 40 µs into sensor HIGH

; -------------------------------------------------------------
;  MQ135 GAS SENSOR THRESHOLDS & HYSTERESIS
; -------------------------------------------------------------
GAS_SAFE_THR    EQU     2000         ; Below this = SAFE (no hysteresis)
GAS_MOD_THR     EQU     2200         ; At/above this = MODERATE
GAS_SEV_THR     EQU     2500        ; At/above this = SEVERE (instant)
YELLOW_HOLD     EQU     3000        ; Loop ticks yellow persists after gas clears

; --- ADC Averaging ---
ADC_STAB_CNT    EQU     600         ; ~3 µs stabilisation burn
ADC_EOC_BIT     EQU     0x02        ; SR end-of-conversion flag
SAMPLE_COUNT    EQU     8           ; Samples per reading
SAMPLE_SHIFT    EQU     3           ; LSR by 3  <=> divide by 8

; -------------------------------------------------------------
;  MAIN LOOP PERIOD
; -------------------------------------------------------------
READING_DELAY   EQU     2000000     ; 2 s between full sensor cycles

; ============================================================
;  DATA SECTION
; ============================================================
        AREA    MyData, DATA, READWRITE

; DHT11 results (inspect in debugger)
temp_int        DCD     0
temp_dec        DCD     0
hum_int         DCD     0
hum_dec         DCD     0
dht_valid       DCD     0           ; 1 = checksum passed
dht_raw         SPACE   5           ; Raw 5-byte frame

; Per-sensor severity outputs
dht_severity    DCD     0           ; 0/1/2 from DHT11
gas_severity    DCD     0           ; 0/1/2 from MQ135

; Gas-sensor hysteresis state
gas_state       DCD     0           ; Current gas LED state (SEV_* values)
gas_yel_timer   DCD     0           ; Yellow hold-off countdown

; Combined output
final_severity  DCD     0           ; MAX(dht_severity, gas_severity)

; ============================================================
;  CODE SECTION
; ============================================================
        AREA    |.text|, CODE, READONLY

__main  FUNCTION

; -- 1. ENABLE CLOCKS -----------------------------------------
    ; AHB1: GPIOA (bit 0) + GPIOB (bit 1)
    LDR     R1, =RCC_BASE + RCC_AHB1ENR
    LDR     R0, [R1]
    ORR     R0, R0, #0x03
    STR     R0, [R1]

    ; APB1: TIM2 (bit 0)
    LDR     R1, =RCC_BASE + RCC_APB1ENR
    LDR     R0, [R1]
    ORR     R0, R0, #0x01
    STR     R0, [R1]

    ; APB2: ADC1 (bit 8)
    LDR     R1, =RCC_BASE + RCC_APB2ENR
    LDR     R0, [R1]
    ORR     R0, R0, #0x0100
    STR     R0, [R1]

; -- 2. GPIOA SETUP -------------------------------------------
;     PA0 = Analog (ADC1 CH0 for MQ135)
;     PA1 = Output, open-drain, pull-up (DHT11 data)

    LDR     R1, =GPIOA_BASE + GPIO_MODER
    LDR     R0, [R1]
    ORR     R0, R0, #0x03           ; PA0 = analog (11)
    BIC     R0, R0, #(3 << 2)
    ORR     R0, R0, #(1 << 2)       ; PA1 = output (01)
    STR     R0, [R1]

    LDR     R1, =GPIOA_BASE + GPIO_OTYPER
    LDR     R0, [R1]
    ORR     R0, R0, #(1 << 1)       ; PA1 = open-drain
    STR     R0, [R1]

    LDR     R1, =GPIOA_BASE + GPIO_OSPEEDR
    LDR     R0, [R1]
    ORR     R0, R0, #(3 << 2)       ; PA1 = high speed
    STR     R0, [R1]

    LDR     R1, =GPIOA_BASE + GPIO_PUPDR
    LDR     R0, [R1]
    BIC     R0, R0, #(3 << 2)
    ORR     R0, R0, #(1 << 2)       ; PA1 = pull-up
    STR     R0, [R1]

    ; Idle DHT11 line HIGH
    LDR     R1, =GPIOA_BASE + GPIO_BSRR
    MOV     R0, #DHT11_MASK
    STR     R0, [R1]

; -- 3. GPIOB SETUP (Traffic LEDs PB0/1/2) --------------------
    LDR     R1, =GPIOB_BASE + GPIO_MODER
    LDR     R0, [R1]
    BIC     R0, R0, #0x3F           ; Clear PB0, PB1, PB2 mode bits
    ORR     R0, R0, #0x15           ; PB0/1/2 = output (01 01 01)
    STR     R0, [R1]

    LDR     R1, =GPIOB_BASE + GPIO_BSRR
    LDR     R0, =(ALL_LEDS << 16)   ; All LEDs OFF
    STR     R0, [R1]

; -- 4. TIM2 @ 1 MHz ------------------------------------------
    LDR     R2, =TIM2_BASE
    MOV     R0, #15                 ; Prescaler: 16 MHz / 16 = 1 MHz
    STR     R0, [R2, #TIM_PSC]
    LDR     R0, =0xFFFFFFFF
    STR     R0, [R2, #TIM_ARR]
    MOV     R0, #1
    STR     R0, [R2, #TIM_EGR]      ; Update event to load PSC/ARR
    STR     R0, [R2, #TIM_CR1]      ; Start counter

; -- 5. ADC1 INIT (Continuous mode on CH0) --------------------
    LDR     R6, =ADC1_BASE          ; R6 = ADC base (permanent)

    LDR     R0, [R6, #ADC_SMPR2]
    ORR     R0, R0, #0x07           ; 480-cycle sample time for MQ135 on CH0
    STR     R0, [R6, #ADC_SMPR2]

    MOV     R0, #0x00
    STR     R0, [R6, #ADC_SQR3]     ; First conversion = CH0

    LDR     R0, [R6, #ADC_CR2]
    ORR     R0, R0, #0x01           ; ADON: Power up ADC
    STR     R0, [R6, #ADC_CR2]

    MOV     R3, #ADC_STAB_CNT       ; Wait for ADC internal caps to settle
adc_stab_loop
    SUBS    R3, R3, #1
    BNE     adc_stab_loop

    LDR     R0, [R6, #ADC_CR2]
    ORR     R0, R0, #(1 << 1)       ; CONT: Continuous conversion mode
    ORR     R0, R0, #(1 << 30)      ; SWSTART: Kick off first conversion
    STR     R0, [R6, #ADC_CR2]

; -- 6. INIT GAS HYSTERESIS STATE -----------------------------
    LDR     R1, =gas_state
    MOV     R0, #SEV_SAFE
    STR     R0, [R1]

    LDR     R1, =gas_yel_timer
    MOV     R0, #0
    STR     R0, [R1]

; -- 7. STARTUP LED -------------------------------------------
    LDR     R1, =GPIOB_BASE + GPIO_BSRR
    MOV     R0, #GREEN_PIN
    STR     R0, [R1]

; ============================================================
;  MAIN LOOP
; ============================================================
main_loop

    ; -- A: Read DHT11 ----------------------------------------
    BL      DHT11_Read

    LDR     R0, =dht_valid
    LDR     R0, [R0]
    CMP     R0, #0
    BEQ     skip_dht_eval           ; Checksum failed: keep last dht_severity

    BL      Evaluate_DHT_Severity   ; -> dht_severity

skip_dht_eval

    ; -- B: Read MQ135 (ADC + hysteresis) ---------------------
    BL      Read_Gas_Sensor         ; -> gas_severity

    ; -- C: Combine — worst case wins -------------------------
    LDR     R0, =dht_severity
    LDR     R0, [R0]
    LDR     R1, =gas_severity
    LDR     R1, [R1]
    CMP     R0, R1
    BGE     combine_use_dht
    MOV     R0, R1                  ; gas is worse
combine_use_dht
    LDR     R2, =final_severity
    STR     R0, [R2]

    ; -- D: Drive LEDs ----------------------------------------
    BL      Update_LEDs

    ; -- E: Wait 2 seconds before next cycle ------------------
    LDR     R0, =READING_DELAY
    BL      Delay_us

    B       main_loop

    ENDFUNC

; ============================================================
;  SUBROUTINE: DHT11_Read
;  Sends start pulse, reads 40 bits, verifies checksum.
;  Sets dht_valid=1 and fills temp_int/dec, hum_int/dec on success.
; ============================================================
DHT11_Read      FUNCTION
    PUSH    {R4-R9, LR}
    LDR     R4, =GPIOA_BASE
    LDR     R5, =dht_raw
    LDR     R9, =dht_valid

    MOV     R0, #0
    STR     R0, [R9]                ; Invalidate until checksum passes

    ; -- Set PA1 as output ------------------------------------
    LDR     R1, =GPIOA_BASE + GPIO_MODER
    LDR     R0, [R1]
    BIC     R0, R0, #(3 << 2)
    ORR     R0, R0, #(1 << 2)
    STR     R0, [R1]

    ; -- Pull bus LOW for 18 ms -------------------------------
    LDR     R0, =(DHT11_MASK << 16)
    STR     R0, [R4, #GPIO_BSRR]
    LDR     R0, =DHT_START_LOW
    BL      Delay_us

    ; -- Release HIGH for 40 µs -------------------------------
    MOV     R0, #DHT11_MASK
    STR     R0, [R4, #GPIO_BSRR]
    LDR     R0, =DHT_START_HIGH
    BL      Delay_us

    ; -- Switch PA1 to input ----------------------------------
    LDR     R1, =GPIOA_BASE + GPIO_MODER
    LDR     R0, [R1]
    BIC     R0, R0, #(3 << 2)
    STR     R0, [R1]

    ; -- Sensor acknowledge sequence --------------------------
    ; Expect: LOW (80 µs), HIGH (80 µs), LOW (data start)
    MOV     R0, #DHT_RESP_TOUT
    BL      Wait_Low
    CMP     R0, #1
    BEQ     dht_fail

    MOV     R0, #DHT_RESP_TOUT
    BL      Wait_High
    CMP     R0, #1
    BEQ     dht_fail

    MOV     R0, #DHT_RESP_TOUT
    BL      Wait_Low
    CMP     R0, #1
    BEQ     dht_fail

    ; -- Read 5 bytes (40 bits) -------------------------------
    MOV     R6, #5                  ; Byte counter
    MOV     R7, R5                  ; Write pointer into dht_raw

dht_byte_loop
    MOV     R8, #8                  ; Bit counter
    MOV     R3, #0                  ; Accumulator

dht_bit_loop
    MOV     R0, #80
    BL      Wait_High               ; Wait for bit HIGH pulse

    MOV     R0, #DHT_BIT_SAMPLE
    BL      Delay_us                ; Sample at 40 µs: '0'<50µs, '1'>50µs

    LSL     R3, R3, #1              ; Shift accumulator left
    LDR     R0, [R4, #GPIO_IDR]
    TST     R0, #DHT11_MASK
    BEQ     dht_bit_zero
    ORR     R3, R3, #1              ; Still HIGH -> bit is '1'
dht_bit_zero
    MOV     R0, #80
    BL      Wait_Low                ; Wait for line to return LOW

    SUBS    R8, R8, #1
    BNE     dht_bit_loop

    STRB    R3, [R7], #1            ; Store byte, advance pointer
    SUBS    R6, R6, #1
    BNE     dht_byte_loop

    ; -- Checksum verification --------------------------------
    ; Expected: byte[4] = (byte[0]+byte[1]+byte[2]+byte[3]) & 0xFF
    LDRB    R0, [R5, #0]
    LDRB    R1, [R5, #1]
    LDRB    R2, [R5, #2]
    LDRB    R3, [R5, #3]
    ADD     R0, R0, R1
    ADD     R0, R0, R2
    ADD     R0, R0, R3
    AND     R0, R0, #0xFF
    LDRB    R1, [R5, #4]
    CMP     R0, R1
    BNE     dht_fail

    ; -- Store decoded values ---------------------------------
    ; dht_raw layout: [hum_int, hum_dec, temp_int, temp_dec, checksum]
    LDRB    R0, [R5, #2]
    LDR     R1, =temp_int
    STR     R0, [R1]

    LDRB    R0, [R5, #3]
    LDR     R1, =temp_dec
    STR     R0, [R1]

    LDRB    R0, [R5, #0]
    LDR     R1, =hum_int
    STR     R0, [R1]

    LDRB    R0, [R5, #1]
    LDR     R1, =hum_dec
    STR     R0, [R1]

    MOV     R0, #1
    STR     R0, [R9]                ; dht_valid = 1

    POP     {R4-R9, PC}

dht_fail
    POP     {R4-R9, PC}             ; Return with dht_valid = 0
    ENDFUNC

; ============================================================
;  SUBROUTINE: Evaluate_DHT_Severity
;  Reads temp_int and hum_int, applies thresholds,
;  writes result to dht_severity. Worst-case between temp/hum wins.
; ============================================================
Evaluate_DHT_Severity   FUNCTION
    PUSH    {R0-R4, LR}

    LDR     R0, =temp_int
    LDR     R0, [R0]                ; R0 = temperature integer part
    LDR     R1, =hum_int
    LDR     R1, [R1]                ; R1 = humidity integer part

    MOV     R2, #SEV_SAFE           ; Start optimistic

    ; -- Temperature evaluation -------------------------------
    CMP     R0, #T_SEVERE_HI
    BGT     ev_sev_t
    CMP     R0, #T_SEVERE_LO
    BLT     ev_sev_t
    CMP     R0, #T_MODERATE_HI
    BGT     ev_mod_t
    CMP     R0, #T_MODERATE_LO
    BLT     ev_mod_t
    B       ev_humidity

ev_sev_t
    MOV     R2, #SEV_SEVERE
    B       ev_humidity

ev_mod_t
    MOV     R2, #SEV_MODERATE

    ; -- Humidity evaluation (only upgrades severity) ---------
ev_humidity
    CMP     R1, #H_SEVERE_HI
    BGT     ev_sev_h
    CMP     R1, #H_SEVERE_LO
    BLT     ev_sev_h
    CMP     R1, #H_MODERATE_HI
    BGT     ev_mod_h
    CMP     R1, #H_MODERATE_LO
    BLT     ev_mod_h
    B       ev_store

ev_sev_h
    MOV     R2, #SEV_SEVERE
    B       ev_store

ev_mod_h
    CMP     R2, #SEV_SEVERE         ; Never downgrade from SEVERE
    BEQ     ev_store
    MOV     R2, #SEV_MODERATE

ev_store
    LDR     R4, =dht_severity
    STR     R2, [R4]

    POP     {R0-R4, PC}
    ENDFUNC

; ============================================================
;  SUBROUTINE: Read_Gas_Sensor
;  Averages 8 ADC samples, applies three-zone hysteresis state
;  machine, writes result to gas_severity.
;
;  Zones:
;    ADC < GAS_SAFE_THR              -> safe (timer may still hold yellow)
;    GAS_SAFE_THR <= ADC < GAS_MOD_THR -> hysteresis (stay in current state)
;    GAS_MOD_THR  <= ADC < GAS_SEV_THR -> moderate
;    ADC >= GAS_SEV_THR              -> severe (instant, kills yellow timer)
; ============================================================
Read_Gas_Sensor     FUNCTION
    PUSH    {R4-R10, LR}

    LDR     R6, =ADC1_BASE          ; R6 = ADC base

    ; -- Average 8 consecutive conversions --------------------
    MOV     R4, #SAMPLE_COUNT
    MOV     R5, #0                  ; Running total

gas_avg_loop
gas_wait_eoc
    LDR     R0, [R6, #ADC_SR]
    TST     R0, #ADC_EOC_BIT
    BEQ     gas_wait_eoc

    LDR     R0, [R6, #ADC_DR]       ; Read clears EOC flag automatically
    ADD     R5, R5, R0
    SUBS    R4, R4, #1
    BNE     gas_avg_loop

    LSR     R5, R5, #SAMPLE_SHIFT   ; R5 = average (total / 8)

    ; -- Load hysteresis state ---------------------------------
    LDR     R7, =gas_state
    LDR     R8, [R7]                ; R8 = current gas state
    LDR     R9, =gas_yel_timer
    LDR     R10, [R9]               ; R10 = yellow hold countdown

    ; -- Decision tree (highest danger first) -----------------

    ; 1. SEVERE?
    LDR     R2, =GAS_SEV_THR
    CMP     R5, R2
    BGE     gas_do_red

    ; 2. MODERATE?
    LDR     R2, =GAS_MOD_THR
    CMP     R5, R2
    BGE     gas_do_yellow_load

    ; 3. HYSTERESIS GAP?
    LDR     R2, =GAS_SAFE_THR
    CMP     R5, R2
    BGE     gas_do_hysteresis

    ; 4. SAFE — is yellow timer still running?
    CMP     R10, #0
    BGT     gas_do_yellow_tick      ; Yes: drain timer, stay yellow
    B       gas_do_green            ; No: go green

    ; -- Hysteresis: hold current state -----------------------
gas_do_hysteresis
    CMP     R8, #SEV_SEVERE
    BEQ     gas_do_red
    CMP     R8, #SEV_MODERATE
    BEQ     gas_do_yellow_load
    B       gas_do_green

    ; -- Yellow: reload or tick hold timer --------------------
gas_do_yellow_load
    LDR     R10, =YELLOW_HOLD       ; Gas still moderate: reset timer
    STR     R10, [R9]
    B       gas_do_yellow_set

gas_do_yellow_tick
    SUB     R10, R10, #1            ; Gas cleared: drain residual timer
    STR     R10, [R9]

gas_do_yellow_set
    MOV     R8, #SEV_MODERATE
    STR     R8, [R7]
    LDR     R0, =gas_severity
    MOV     R1, #SEV_MODERATE
    STR     R1, [R0]
    POP     {R4-R10, PC}

    ; -- Green -------------------------------------------------
gas_do_green
    MOV     R8, #SEV_SAFE
    STR     R8, [R7]
    MOV     R10, #0
    STR     R10, [R9]
    LDR     R0, =gas_severity
    MOV     R1, #SEV_SAFE
    STR     R1, [R0]
    POP     {R4-R10, PC}

    ; -- Red (immediate, kills yellow timer) ------------------
gas_do_red
    MOV     R8, #SEV_SEVERE
    STR     R8, [R7]
    MOV     R10, #0
    STR     R10, [R9]
    LDR     R0, =gas_severity
    MOV     R1, #SEV_SEVERE
    STR     R1, [R0]
    POP     {R4-R10, PC}

    ENDFUNC

; ============================================================
;  SUBROUTINE: Update_LEDs
;  Reads final_severity, atomically drives PB0/1/2.
; ============================================================
Update_LEDs         FUNCTION
    PUSH    {R0-R2, LR}

    LDR     R2, =final_severity
    LDR     R2, [R2]
    LDR     R1, =GPIOB_BASE + GPIO_BSRR

    LDR     R0, =(ALL_LEDS << 16)   ; Atomically clear all three LEDs
    STR     R0, [R1]

    CMP     R2, #SEV_SEVERE
    BEQ     ul_red
    CMP     R2, #SEV_MODERATE
    BEQ     ul_yellow

ul_green                            ; SEV_SAFE
    MOV     R0, #GREEN_PIN
    STR     R0, [R1]
    B       ul_done

ul_red
    MOV     R0, #RED_PIN
    STR     R0, [R1]
    B       ul_done

ul_yellow
    MOV     R0, #YELLOW_PIN
    STR     R0, [R1]

ul_done
    POP     {R0-R2, PC}
    ENDFUNC

; ============================================================
;  TIMING SUBROUTINES (all rely on TIM2 @ 1 MHz)
; ============================================================

; -- Delay_us -------------------------------------------------
; R0 = number of microseconds to wait (blocking).
Delay_us            FUNCTION
    PUSH    {R1-R3, LR}
    LDR     R1, =TIM2_BASE
    LDR     R2, [R1, #TIM_CNT]      ; Snapshot start time
du_loop
    LDR     R3, [R1, #TIM_CNT]
    SUB     R3, R3, R2              ; Elapsed (handles 32-bit wrap)
    CMP     R3, R0
    BLO     du_loop
    POP     {R1-R3, PC}
    ENDFUNC

; -- Wait_Low -------------------------------------------------
; R0 = timeout in µs. Returns R0=0 on success, R0=1 on timeout.
; Waits until PA1 goes LOW.
Wait_Low            FUNCTION
    PUSH    {R1-R5, LR}
    MOV     R5, R0
    LDR     R3, =GPIOA_BASE + GPIO_IDR
    LDR     R4, =TIM2_BASE
    LDR     R2, [R4, #TIM_CNT]
wl_poll
    LDR     R1, [R3]
    TST     R1, #DHT11_MASK
    BEQ     wl_ok                   ; PA1 is LOW — success
    LDR     R1, [R4, #TIM_CNT]
    SUB     R1, R1, R2
    CMP     R1, R5
    BLO     wl_poll
    MOV     R0, #1                  ; Timeout
    POP     {R1-R5, PC}
wl_ok
    MOV     R0, #0
    POP     {R1-R5, PC}
    ENDFUNC

; -- Wait_High ------------------------------------------------
; R0 = timeout in µs. Returns R0=0 on success, R0=1 on timeout.
; Waits until PA1 goes HIGH.
Wait_High           FUNCTION
    PUSH    {R1-R5, LR}
    MOV     R5, R0
    LDR     R3, =GPIOA_BASE + GPIO_IDR
    LDR     R4, =TIM2_BASE
    LDR     R2, [R4, #TIM_CNT]
wh_poll
    LDR     R1, [R3]
    TST     R1, #DHT11_MASK
    BNE     wh_ok                   ; PA1 is HIGH — success
    LDR     R1, [R4, #TIM_CNT]
    SUB     R1, R1, R2
    CMP     R1, R5
    BLO     wh_poll
    MOV     R0, #1                  ; Timeout
    POP     {R1-R5, PC}
wh_ok
    MOV     R0, #0
    POP     {R1-R5, PC}
    ENDFUNC

    END