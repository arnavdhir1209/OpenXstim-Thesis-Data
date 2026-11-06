
/*
  OpenXstim v1.3 - Timing and Controller Diagnostics
  Arduino Uno R4 / AD5722

  BENCH RESISTOR LOADS ONLY.
  NOT FOR HUMAN STIMULATION.

  Timing state bits:
    Bit 0 = D5
    Bit 1 = D8
    Bit 2 = A2

    000 Idle / UI / OFF delay
    001 Positive DAC write
    010 ADC settling
    011 ADC acquisition
    100 Baseline DAC write
    101 Burst measurement finalisation
    110 Controller and supervisor
    111 CSV logging
*/

#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <stdint.h>
#include <math.h>
#include <AD57.h>

// ============================================================
// STIMULATION PARAMETERS
// ============================================================

#define pulse_number 20
#define pulse_width 10
#define ADC_SAMPLES_PER_PULSE 8
#define ADC_SETTLE_US 200
#define RAW_SENSE_PIN A0

#define DAC_CHANNEL DAC_AB
#define output_range pn5V

// Timing instrumentation pins
#define DEBUG_BIT0_PIN 5
#define DEBUG_BIT1_PIN 8
#define DEBUG_BIT2_PIN A2

#define ENC_A 3
#define ENC_B 2
#define Push_BUTTON 4

#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 32

#define TIMING_IDLE         0
#define TIMING_POS_DAC      1
#define TIMING_SETTLE       2
#define TIMING_ADC          3
#define TIMING_BASELINE_DAC 4
#define TIMING_FINALISE     5
#define TIMING_CONTROL      6
#define TIMING_CSV          7

// ============================================================
// CONTROL MODES
// ============================================================

enum ControlMode {
    OPEN_LOOP,
    P_CONTROL,
    PI_CONTROL
};

// Select the mode to investigate
const ControlMode CONTROL_MODE = PI_CONTROL;

enum StimState {
    DISABLED,
    RUNNING,
    FAULT_LATCHED
};

enum FaultCode {
    FAULT_NONE,
    FAULT_ADC_RANGE,
    FAULT_OVERCURRENT
};

// ============================================================
// CONTROLLER SETTINGS - UNCHANGED
// ============================================================

const float calibration = 21.5f;

const float ADC_REF_V = 4.883f;
const float ADC_MAX = 16383.0f;
const float R_CURRENT_SENSE_OHMS = 10.0f;

const float INITIAL_TARGET_CURRENT_MA = 10.0f;
const float MAX_REQUEST_MA = 25.0f;
const float MAX_TEST_CURRENT_MA = 15.0f;

// Retained abnormal-current stop threshold
const float MAX_MEASURED_MA = 16.0f;

const float KP_COUNTS_PER_MA = 4.867577f;
const float KI_COUNTS_PER_MA_S = 9.758558f;

const float MAX_TRIM_COUNTS = 25.0f;
const float ERROR_DEADBAND_MA = 0.060f;

// ============================================================
// PERFORMANCE WARNING THRESHOLDS
// ============================================================

const float LOW_CURRENT_MA = 0.30f;
const float LOSS_CHECK_TARGET_MA = 3.0f;

const float PLATEAU_ERROR_MA = 0.15f;
const float PLATEAU_RESPONSE_MA = 0.08f;

const unsigned int PLATEAU_DAC_STEP = 8;

const uint8_t STARTUP_GRACE_BURSTS = 2;
const uint8_t LOW_CURRENT_FAULT_BURSTS = 2;
const uint8_t LIMIT_FAULT_BURSTS = 15;

// Diagnostic warning bits
#define WARN_CURRENT_LOSS  0x01
#define WARN_COMMAND_LIMIT 0x02
#define WARN_NO_RESPONSE   0x04

uint8_t diagnosticFlags = 0;

// ============================================================
// BUTTON AND LOGGING
// ============================================================

const unsigned long BUTTON_DEBOUNCE_MS = 40;
const unsigned long BUTTON_LONG_MS = 1200;

const unsigned long IDLE_REPORT_MS = 500;
const unsigned long DISPLAY_REFRESH_MS = 150;

const bool CSV_LOGGING_ENABLED = true;
const bool PRINT_PULSE_DEBUG = false;

unsigned long burstNumber = 0;

// ============================================================
// DAC AND ENCODER VARIABLES
// ============================================================

uint8_t DacType = AD5722;
char slave_pin_DAC = 9;

int16_t baseline = 2048;
int16_t value = 2048;
int16_t initial_value = 0x0fff;

volatile unsigned int Counter = 0;
unsigned int driveCounter = 0;

volatile int frequencySetting = 20;
volatile bool frequencyMenu = false;

unsigned long _lastIncReadTime = 0;
unsigned long _lastDecReadTime = 0;

// ============================================================
// MEASUREMENT AND CONTROLLER STATE
// ============================================================

float senseAverage[pulse_number];

Adafruit_SSD1306 display(
    SCREEN_WIDTH,
    SCREEN_HEIGHT,
    &Wire,
    -1
);

StimState stimState = DISABLED;
FaultCode faultCode = FAULT_NONE;

float iTermCounts = 0.0f;

uint32_t lastControllerUs = 0;

unsigned long lastIdleReportMs = 0;
unsigned long lastDisplayMs = 0;

uint8_t startupBursts = 0;
uint8_t lowCurrentBursts = 0;
uint8_t limitErrorBursts = 0;

bool plateauAnchorValid = false;
unsigned int plateauAnchorCounter = 0;
float plateauAnchorCurrent = 0.0f;

unsigned int lastRequestedCounter = 0;

// ============================================================
// BUTTON STATE
// ============================================================

bool buttonRawPressed = false;
bool buttonStablePressed = false;
bool buttonLongHandled = false;

unsigned long buttonRawChangedAt = 0;
unsigned long buttonPressedAt = 0;

// ============================================================
// FUNCTION DECLARATIONS
// ============================================================

void read_encoder();
void init_AD57xx();

void setDebugState(uint8_t state);
void commandBaseline();
void disableStimulation();
void latchFault(FaultCode code);

void handleButton();
void refreshDisplay();

void printRecord(
    unsigned int applied,
    unsigned int nextCounter,
    float requested,
    float effective,
    float measured,
    bool measuredValid,
    float error,
    bool errorValid,
    float pTerm,
    bool commandLimited,
    bool referenceLimited,
    float dtMs
);

// ============================================================
// LABEL FUNCTIONS
// ============================================================

const char* modeName() {

    switch (CONTROL_MODE) {
        case OPEN_LOOP: return "OPEN_LOOP";
        case P_CONTROL: return "P_CONTROL";
        default: return "PI_CONTROL";
    }
}

const char* stateName() {

    switch (stimState) {
        case RUNNING: return "RUNNING";
        case FAULT_LATCHED: return "FAULT_LATCHED";
        default: return "DISABLED";
    }
}

const char* faultName() {

    switch (faultCode) {
        case FAULT_ADC_RANGE: return "ADC_RANGE";
        case FAULT_OVERCURRENT: return "OVERCURRENT";
        default: return "NONE";
    }
}

// ============================================================
// DAC COMMAND BOUND
// ============================================================

unsigned int maxAllowedCounts() {

    float ceiling =
        floorf(MAX_TEST_CURRENT_MA * calibration);

    if (ceiling > 2047.0f) {
        ceiling = 2047.0f;
    }

    if (ceiling < 0.0f) {
        ceiling = 0.0f;
    }

    return (unsigned int)ceiling;
}

// ============================================================
// BASELINE COMMAND - ALSO MARKS THE EXTRA END-OF-BURST WRITE
// ============================================================

void commandBaseline() {

    setDebugState(TIMING_BASELINE_DAC);

    AD57.setDac(DAC_CHANNEL, baseline);

    setDebugState(TIMING_IDLE);
}

// ============================================================
// STATE MANAGEMENT
// ============================================================

void clearControllerHistory() {

    iTermCounts = 0.0f;
    driveCounter = 0;

    lastControllerUs = 0;

    startupBursts = 0;
    lowCurrentBursts = 0;
    limitErrorBursts = 0;

    plateauAnchorValid = false;
    diagnosticFlags = 0;
}

void disableStimulation() {

    commandBaseline();

    stimState = DISABLED;

    clearControllerHistory();
}

void latchFault(FaultCode code) {

    // Stop output before doing anything else.
    commandBaseline();

    setDebugState(TIMING_CONTROL);

    stimState = FAULT_LATCHED;
    faultCode = code;

    clearControllerHistory();
}

void startStimulation() {

    if (stimState != DISABLED || frequencyMenu) {
        return;
    }

    unsigned int req;

    noInterrupts();
    req = Counter;
    interrupts();

    if (req == 0) {
        return;
    }

    faultCode = FAULT_NONE;
    clearControllerHistory();

    driveCounter =
        (req > maxAllowedCounts())
        ? maxAllowedCounts()
        : req;

    lastRequestedCounter = req;

    stimState = RUNNING;
}

// ============================================================
// BUTTON INTERFACE
// ============================================================

void handleShortPress() {

    if (stimState == FAULT_LATCHED) {
        return;
    }

    if (frequencyMenu) {

        frequencyMenu = false;
    }
    else if (stimState == RUNNING) {

        disableStimulation();
    }
    else {

        startStimulation();
    }
}

void handleLongPress() {

    if (stimState == FAULT_LATCHED) {

        faultCode = FAULT_NONE;
        disableStimulation();
        return;
    }

    if (stimState == RUNNING) {
        disableStimulation();
    }

    frequencyMenu = !frequencyMenu;
}

void handleButton() {

    unsigned long now = millis();

    bool raw =
        (digitalRead(Push_BUTTON) == LOW);

    if (raw != buttonRawPressed) {

        buttonRawPressed = raw;
        buttonRawChangedAt = now;
    }

    if (
        now - buttonRawChangedAt <
        BUTTON_DEBOUNCE_MS
    ) {
        return;
    }

    if (raw != buttonStablePressed) {

        buttonStablePressed = raw;

        if (raw) {

            buttonPressedAt = now;
            buttonLongHandled = false;
        }
        else if (!buttonLongHandled) {

            handleShortPress();
        }
    }

    if (
        buttonStablePressed &&
        !buttonLongHandled &&
        now - buttonPressedAt >= BUTTON_LONG_MS
    ) {

        buttonLongHandled = true;
        handleLongPress();
    }
}

// ============================================================
// OLED DISPLAY
// ============================================================

void refreshDisplay() {

    unsigned long now = millis();

    if (
        now - lastDisplayMs <
        DISPLAY_REFRESH_MS
    ) {
        return;
    }

    lastDisplayMs = now;

    unsigned int req;
    int hz;

    noInterrupts();
    req = Counter;
    hz = frequencySetting;
    interrupts();

    display.clearDisplay();
    display.setTextColor(WHITE);
    display.setCursor(0, 0);
    display.setTextSize(2);

    if (frequencyMenu) {

        display.print(hz);
        display.println(F(" Hz"));
    }
    else {

        display.print(
            (float)req / calibration, 1
        );
        display.println(F(" mA"));
    }

    display.setTextSize(1);
    display.setCursor(0, 22);

    if (frequencyMenu) {
        display.print(F("FREQ MENU - OUTPUT OFF"));
    }
    else if (stimState == FAULT_LATCHED) {

        display.print(F("FAULT: "));
        display.print(faultName());
    }
    else {

        display.print(stateName());
        display.print(F(" "));
        display.print(modeName());
    }

    display.display();
}

// ============================================================
// EXISTING CSV FORMAT - 17 FIELDS
// ============================================================

void printRecord(
    unsigned int applied,
    unsigned int nextCounter,
    float requested,
    float effective,
    float measured,
    bool measuredValid,
    float error,
    bool errorValid,
    float pTerm,
    bool commandLimited,
    bool referenceLimited,
    float dtMs
) {

    if (!CSV_LOGGING_ENABLED) {
        return;
    }

    Serial.print(F("DATA,"));

    Serial.print(millis());
    Serial.print(',');

    Serial.print(burstNumber);
    Serial.print(',');

    Serial.print(modeName());
    Serial.print(',');

    Serial.print(stateName());
    Serial.print(',');

    Serial.print(requested, 3);
    Serial.print(',');

    Serial.print(effective, 3);
    Serial.print(',');

    Serial.print(
        (float)applied / calibration, 3
    );
    Serial.print(',');

    if (measuredValid) {
        Serial.print(measured, 3);
    }
    Serial.print(',');

    if (errorValid) {
        Serial.print(error, 3);
    }
    Serial.print(',');

    Serial.print(applied);
    Serial.print(',');

    Serial.print(nextCounter);
    Serial.print(',');

    Serial.print(pTerm, 3);
    Serial.print(',');

    Serial.print(iTermCounts, 3);
    Serial.print(',');

    Serial.print(commandLimited ? 1 : 0);
    Serial.print(',');

    Serial.print(referenceLimited ? 1 : 0);
    Serial.print(',');

    Serial.print(faultName());
    Serial.print(',');

    Serial.println(dtMs, 2);
}

// ============================================================
// SETUP
// ============================================================

void setup() {

    pinMode(Push_BUTTON, INPUT_PULLUP);

    pinMode(ENC_A, INPUT_PULLUP);
    pinMode(ENC_B, INPUT_PULLUP);

    pinMode(DEBUG_BIT0_PIN, OUTPUT);
    pinMode(DEBUG_BIT1_PIN, OUTPUT);
    pinMode(DEBUG_BIT2_PIN, OUTPUT);

    setDebugState(TIMING_IDLE);

    Serial.begin(115200);

    AD57.debug(0);
    init_AD57xx();

    commandBaseline();

    if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {

        Serial.println(
            F("SSD1306 initialization failed")
        );

        for (;;) {
            delay(100);
        }
    }

    analogReference(AR_DEFAULT);
    analogReadResolution(14);

    delay(5);

    for (int i = 0; i < 5; ++i) {
        analogRead(RAW_SENSE_PIN);
    }

    Counter = (unsigned int)roundf(
        INITIAL_TARGET_CURRENT_MA * calibration
    );

    buttonRawPressed =
        (digitalRead(Push_BUTTON) == LOW);

    buttonStablePressed = buttonRawPressed;
    buttonLongHandled = buttonStablePressed;
    buttonPressedAt = millis();

    attachInterrupt(
        digitalPinToInterrupt(ENC_A),
        read_encoder,
        CHANGE
    );

    attachInterrupt(
        digitalPinToInterrupt(ENC_B),
        read_encoder,
        CHANGE
    );

    refreshDisplay();

    // Output remains disabled until deliberately started.
}

// ============================================================
// MAIN LOOP
// ============================================================

void loop() {

    handleButton();
    refreshDisplay();

    // ========================================================
    // READ ENCODER SETPOINT
    // ========================================================

    unsigned int req;

    noInterrupts();
    req = Counter;
    interrupts();

    float requested_mA =
        (float)req / calibration;

    unsigned int boundedReq =
        (req > maxAllowedCounts())
        ? maxAllowedCounts()
        : req;

    float effective_mA =
        (float)boundedReq / calibration;

    bool referenceLimited =
        (req > boundedReq);

    // ========================================================
    // DISABLED / FAULT HANDLING
    // ========================================================

    if (
        stimState != RUNNING ||
        frequencyMenu ||
        boundedReq == 0
    ) {

        if (
            stimState == RUNNING &&
            boundedReq == 0
        ) {
            disableStimulation();
        }

        if (
            millis() - lastIdleReportMs >=
            IDLE_REPORT_MS
        ) {

            lastIdleReportMs = millis();

            setDebugState(TIMING_CSV);

            printRecord(
                0, 0,
                requested_mA,
                effective_mA,
                0.0f, false,
                0.0f, false,
                0.0f, false,
                referenceLimited,
                0.0f
            );

            setDebugState(TIMING_IDLE);
        }

        delay(5);
        return;
    }

    // ========================================================
    // RESET INTEGRATOR ON REFERENCE CHANGE
    // ========================================================

    if (req != lastRequestedCounter) {

        iTermCounts = 0.0f;

        plateauAnchorValid = false;
        limitErrorBursts = 0;

        lastRequestedCounter = req;
    }

    // ========================================================
    // SELECT BOUNDED DAC COMMAND
    // ========================================================

    unsigned int appliedCounter =
        (CONTROL_MODE == OPEN_LOOP)
        ? boundedReq
        : driveCounter;

    bool appliedLimited =
        (appliedCounter > maxAllowedCounts());

    if (appliedLimited) {
        appliedCounter = maxAllowedCounts();
    }

    value = baseline + appliedCounter;

    // ========================================================
    // ACQUISITION
    // ========================================================

    bool adcInvalid = false;
    bool overcurrent = false;

    unsigned int collectedPulses = 0;
    float currentSum = 0.0f;

    for (int i = 0; i < pulse_number; ++i) {

        // STATE 1: Positive DAC write
        setDebugState(TIMING_POS_DAC);

        AD57.setDac(DAC_CHANNEL, value);

        // STATE 2: Settling delay
        setDebugState(TIMING_SETTLE);

        delayMicroseconds(ADC_SETTLE_US);

        uint32_t adcSum = 0;

        // STATE 3: Eight ADC samples and processing
        setDebugState(TIMING_ADC);

        for (
            int s = 0;
            s < ADC_SAMPLES_PER_PULSE;
            ++s
        ) {

            int raw = analogRead(RAW_SENSE_PIN);

            adcSum += (uint32_t)raw;

            if (
                raw < 0 ||
                raw >= (int)ADC_MAX
            ) {
                adcInvalid = true;
            }

            float instantCurrent =
                (float)raw *
                (ADC_REF_V / ADC_MAX) *
                (1000.0f / R_CURRENT_SENSE_OHMS);

            if (
                instantCurrent > MAX_MEASURED_MA
            ) {
                overcurrent = true;
            }
        }

        senseAverage[i] =
            (float)adcSum / ADC_SAMPLES_PER_PULSE;

        float measuredPulse =
            senseAverage[i] *
            (ADC_REF_V / ADC_MAX) *
            (1000.0f / R_CURRENT_SENSE_OHMS);

        currentSum += measuredPulse;

        ++collectedPulses;

        // STATE 4: Per-pulse baseline DAC write
        setDebugState(TIMING_BASELINE_DAC);

        AD57.setDac(DAC_CHANNEL, baseline);

        setDebugState(TIMING_IDLE);

        // Preserve abnormal-current / ADC shutdown.
        if (adcInvalid || overcurrent) {
            break;
        }

        delayMicroseconds(pulse_width);
    }

    // Extra end-of-burst baseline DAC write.
    // Marked separately as State 4.
    commandBaseline();

    // ========================================================
    // OPTIONAL PULSE DEBUG OUTPUT
    // ========================================================

    if (PRINT_PULSE_DEBUG) {

        setDebugState(TIMING_CSV);

        for (
            unsigned int i = 0;
            i < collectedPulses;
            ++i
        ) {

            Serial.print(F("PULSE,"));
            Serial.print(burstNumber + 1);
            Serial.print(',');
            Serial.print(i + 1);
            Serial.print(',');
            Serial.println(senseAverage[i], 2);
        }

        setDebugState(TIMING_IDLE);
    }

    // ========================================================
    // STATE 5: FINALISE MEASUREMENT
    // ========================================================

    setDebugState(TIMING_FINALISE);

    ++burstNumber;

    float measured_mA =
        collectedPulses
        ? currentSum / collectedPulses
        : 0.0f;

    bool completeBurst =
        (collectedPulses == pulse_number);

    uint32_t sampleFinishedUs = micros();

    float dt_s = 0.0f;

    if (lastControllerUs != 0) {

        dt_s =
            (float)(uint32_t)(
                sampleFinishedUs - lastControllerUs
            ) / 1000000.0f;
    }

    lastControllerUs = sampleFinishedUs;

    // ========================================================
    // STATE 6: CONTROLLER AND SAFETY SUPERVISOR
    // ========================================================

    setDebugState(TIMING_CONTROL);

    // Retained critical fault handling
    if (
        adcInvalid ||
        !isfinite(measured_mA) ||
        !completeBurst
    ) {

        latchFault(FAULT_ADC_RANGE);
    }
    else if (
        overcurrent ||
        measured_mA > MAX_MEASURED_MA
    ) {

        latchFault(FAULT_OVERCURRENT);
    }

    float error_mA =
        effective_mA - measured_mA;

    float pTerm = 0.0f;

    bool commandLimited = appliedLimited;
    unsigned int nextCounter = 0;

    // ========================================================
    // CURRENT-LOSS DIAGNOSTIC (NO SOFT FAULT LATCH)
    // ========================================================

    if (stimState == RUNNING) {

        ++startupBursts;

        if (
            effective_mA >= LOSS_CHECK_TARGET_MA &&
            measured_mA < LOW_CURRENT_MA &&
            startupBursts > STARTUP_GRACE_BURSTS
        ) {

            ++lowCurrentBursts;
        }
        else {

            lowCurrentBursts = 0;
        }

        if (
            lowCurrentBursts >=
            LOW_CURRENT_FAULT_BURSTS
        ) {

            diagnosticFlags |= WARN_CURRENT_LOSS;
        }
    }

    // ========================================================
    // OPEN LOOP / P / PI CALCULATION
    // ========================================================

    if (stimState == RUNNING) {

        float adjustedError =
            (fabsf(error_mA) <= ERROR_DEADBAND_MA)
            ? 0.0f
            : error_mA;

        if (CONTROL_MODE == OPEN_LOOP) {

            pTerm = 0.0f;
        }
        else {

            pTerm =
                KP_COUNTS_PER_MA * adjustedError;
        }

        float ff = (float)boundedReq;

        float lower = 0.0f;
        float upper = (float)maxAllowedCounts();

        if (CONTROL_MODE != OPEN_LOOP) {

            lower = fmaxf(
                lower,
                ff - MAX_TRIM_COUNTS
            );

            upper = fminf(
                upper,
                ff + MAX_TRIM_COUNTS
            );
        }

        // ====================================================
        // EXISTING CONDITIONAL ANTI-WINDUP
        // ====================================================

        if (
            CONTROL_MODE == PI_CONTROL &&
            dt_s > 0.0f
        ) {

            float dt = fminf(dt_s, 0.5f);

            float deltaI =
                KI_COUNTS_PER_MA_S *
                adjustedError *
                dt;

            float tentativeI =
                iTermCounts + deltaI;

            float tentativeCommand =
                ff + pTerm + tentativeI;

            bool pushingUpper =
                (
                    tentativeCommand > upper &&
                    deltaI > 0.0f
                );

            bool pushingLower =
                (
                    tentativeCommand < lower &&
                    deltaI < 0.0f
                );

            if (!pushingUpper && !pushingLower) {

                iTermCounts = tentativeI;
            }
        }

        if (CONTROL_MODE != PI_CONTROL) {
            iTermCounts = 0.0f;
        }

        float proposed =
            ff + pTerm + iTermCounts;

        float bounded = proposed;

        if (bounded < lower) {
            bounded = lower;
        }

        if (bounded > upper) {
            bounded = upper;
        }

        commandLimited =
            commandLimited ||
            (fabsf(bounded - proposed) > 0.001f) ||
            (
                bounded >= upper - 0.5f &&
                adjustedError > 0.0f
            ) ||
            (
                bounded <= lower + 0.5f &&
                adjustedError < 0.0f
            );

        driveCounter =
            (unsigned int)roundf(bounded);

        nextCounter = driveCounter;

        // ====================================================
        // COMMAND LIMIT DIAGNOSTIC - NO SOFT FAULT LATCH
        // ====================================================

        if (
            CONTROL_MODE != OPEN_LOOP &&
            commandLimited &&
            fabsf(error_mA) > PLATEAU_ERROR_MA
        ) {

            ++limitErrorBursts;
        }
        else {

            limitErrorBursts = 0;
        }

        if (
            limitErrorBursts >= LIMIT_FAULT_BURSTS
        ) {

            diagnosticFlags |= WARN_COMMAND_LIMIT;
        }

        // ====================================================
        // RESPONSE DIAGNOSTIC - NO SOFT FAULT LATCH
        // ====================================================

        if (
            CONTROL_MODE != OPEN_LOOP &&
            error_mA > PLATEAU_ERROR_MA
        ) {

            if (!plateauAnchorValid) {

                plateauAnchorCounter = appliedCounter;
                plateauAnchorCurrent = measured_mA;
                plateauAnchorValid = true;
            }
            else if (
                appliedCounter >=
                plateauAnchorCounter + PLATEAU_DAC_STEP
            ) {

                float currentIncrease =
                    measured_mA - plateauAnchorCurrent;

                if (
                    currentIncrease < PLATEAU_RESPONSE_MA
                ) {

                    diagnosticFlags |= WARN_NO_RESPONSE;
                }
                else {

                    plateauAnchorCounter = appliedCounter;
                    plateauAnchorCurrent = measured_mA;
                }
            }
        }
        else {

            plateauAnchorValid = false;
        }
    }

    // ========================================================
    // LOG COMPLETED UPDATE
    // ========================================================

    if (stimState != RUNNING) {
        nextCounter = 0;
    }

    setDebugState(TIMING_CSV);

    printRecord(
        appliedCounter,
        nextCounter,
        requested_mA,
        effective_mA,
        measured_mA,
        completeBurst,
        error_mA,
        completeBurst && stimState == RUNNING,
        pTerm,
        commandLimited,
        referenceLimited,
        dt_s * 1000.0f
    );

    setDebugState(TIMING_IDLE);

    if (stimState != RUNNING) {
        return;
    }

    // ========================================================
    // ORIGINAL INTER-BURST DELAY AND UI
    // ========================================================

    int hz;

    noInterrupts();
    hz = frequencySetting;
    interrupts();

    delay(700 / hz);

    handleButton();
    refreshDisplay();
}

// ============================================================
// ENCODER INTERRUPT
// ============================================================

void read_encoder() {

    static uint8_t old_AB = 3;
    static int8_t encval = 0;

    static const int8_t enc_states[] = {
         0, -1,  1,  0,
         1,  0,  0, -1,
        -1,  0,  0,  1,
         0,  1, -1,  0
    };

    old_AB <<= 2;

    if (digitalRead(ENC_A)) {
        old_AB |= 0x02;
    }

    if (digitalRead(ENC_B)) {
        old_AB |= 0x01;
    }

    encval += enc_states[old_AB & 0x0f];

    if (encval > 3 || encval < -3) {

        int direction =
            (encval > 3) ? 1 : -1;

        unsigned long now = micros();

        if (direction > 0) {
            _lastIncReadTime = now;
        }
        else {
            _lastDecReadTime = now;
        }

        if (frequencyMenu) {

            int nextHz =
                frequencySetting + direction;

            if (nextHz < 1) {
                nextHz = 1;
            }

            if (nextHz > 50) {
                nextHz = 50;
            }

            frequencySetting = nextHz;
        }
        else {

            int32_t nextSetpoint =
                (int32_t)Counter +
                (int32_t)direction * 5;

            int32_t maxReq =
                (int32_t)roundf(
                    MAX_REQUEST_MA * calibration
                );

            if (nextSetpoint < 0) {
                nextSetpoint = 0;
            }

            if (nextSetpoint > maxReq) {
                nextSetpoint = maxReq;
            }

            Counter =
                (unsigned int)nextSetpoint;
        }

        encval = 0;
    }
}

// ============================================================
// DAC INITIALIZATION
// ============================================================

void init_AD57xx() {

    AD57.begin(DAC_CHANNEL, output_range);

    Serial.print(F("get range "));
    Serial.println(AD57.getRange(DAC_CHANNEL));

    AD57.setControl(
        OP_INSTR,
        (
            SET_TSD_ENABLE |
            SET_CLAMP_ENABLE |
            STOP_CLR_SET
        )
    );

    AD57.setControl(OP_CLEAR);
}

// ============================================================
// TIMING STATE HELPER
// ============================================================

void setDebugState(uint8_t state) {

    digitalWrite(
        DEBUG_BIT0_PIN,
        (state >> 0) & 0x01
    );

    digitalWrite(
        DEBUG_BIT1_PIN,
        (state >> 1) & 0x01
    );

    digitalWrite(
        DEBUG_BIT2_PIN,
        (state >> 2) & 0x01
    );
}
