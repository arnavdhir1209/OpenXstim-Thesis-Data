# OpenXstim Thesis Data Release

Raw data, simulation outputs and code from an honours thesis on sampled delivered current feedback for the OpenXstim stimulator (Arduino Uno R4, AD5722 DAC, OPA454 Howland current pump). The thesis designs PI controllers that use a burst averaged measurement of the delivered current, tests them in simulation, and compares them with open loop operation on the bench.

**Conditions.** Every recording was made on the bench with resistive loads only (100 Ω to 5.7 kΩ). The experiments used a monophasic pulse waveform, with the output capacitor C15 bypassed. Nothing here was recorded on people, and the firmware and settings are **not for use on people**.

## Folder layout

| Folder | Contents |
|---|---|
| `Experiment1_OpenLoopBaseline/` | open loop at Counter 215, six loads, two recordings each |
| `Experiment2_OpenLoopSweep/` | open loop command sweeps, six loads |
| `Experiment3_ControllerComparison/` | empirical and faster PI, six loads, five recordings each |
| `Experiment4_DeadbandComparison/` | faster PI, deadband 0.030, 0.045 and 0.060 mA, at 100 Ω and 4 kΩ, five recordings each |
| `Simulation1_IdealLinear/` to `Simulation5_HardwareMatched/` | outputs of the five simulation studies |
| `Simulation3_Robustness/noise_models/` | residual noise models N1 to N6 |
| `EarlySimulation_Stage1/` | output of the first Simulink model (V3) |
| `Characterisation_EarlyRecordings/` | B1 to B4 recordings, early DAC sweeps (voltage limit), early P and PI tests, five unlabelled logger sessions from 14 October 2026 |
| `Characterisation_Oscilloscope/` | oscilloscope exports under 50 MB: `DefaultOutput` (original firmware), `PulseDynamics` (rise and fall, long pulse), `CommandDelay` (command to output delay) |
| `code/` | analysis scripts, Simulink models and the logger, in folders matching the data folders |
| `MANIFEST.csv` | one row per released file: release path, original path, size, SHA-256 |

## Thesis names and internal labels

| Thesis name | Release folder | Internal label |
|---|---|---|
| Experiment 1, open loop baseline | `Experiment1_OpenLoopBaseline` | E01 |
| Experiment 2, open loop command sweep | `Experiment2_OpenLoopSweep` | E02 |
| Experiment 3, controller comparison | `Experiment3_ControllerComparison` | E03 |
| Experiment 4, deadband comparison | `Experiment4_DeadbandComparison` | E04 |
| Simulation 1, ideal linear design | `Simulation1_IdealLinear` | Stage 2A |
| Simulation 2, firmware representative | `Simulation2_FirmwareRepresentative` | Stage 2B |
| Simulation 3, robustness study | `Simulation3_Robustness` | Stage 2C |
| Simulation 4, deadband sensitivity | `Simulation4_DeadbandSensitivity` | Stage 2D |
| Simulation 5, hardware matched simulation | `Simulation5_HardwareMatched` | Stage 2E |
| Early recordings used for the design model | `Characterisation_EarlyRecordings` | B1 (2 kΩ open loop), B2 (4 kΩ open loop), B3 (2 kΩ), B4 (4 kΩ closed loop, empirical) |
| Oscilloscope captures | `Characterisation_Oscilloscope` | V1 to V4 |
| Noise models | `Simulation3_Robustness/noise_models` | N1 to N6 |
| Empirical PI, faster PI, intermediate PI | file names `EmpiricalPI`, `FasterPI`, `IntermediatePI` | PI_E, PI_F, Conservative |

Loads in file names are `100R`, `220R`, `560R`, `1k`, `2k` and `4k`, and repeats are `rec01`, `rec02` and so on. The measured resistances were 99.5, 218, 558, 997, 1980 and 3970 Ω.

## File formats

### Serial logs (experiments, B1 to B4, early P and PI tests, unlabelled sessions)
One row per controller update (one burst of 20 pulses). Rows with `stim_state` other than RUNNING are idle reports.

| Column | Unit | Meaning |
|---|---|---|
| `time_ms` | ms | Arduino `millis()` when the row was printed |
| `burst` | count | burst number since power up |
| `mode` | | OPEN_LOOP, P_CONTROL or PI_CONTROL |
| `stim_state` | | DISABLED, RUNNING or FAULT_LATCHED |
| `requested_mA` | mA | reference set on the encoder (Counter/21.5) |
| `effective_target_mA` | mA | reference after the safety limit |
| `command_mA` | mA | applied command expressed as current (counter_applied/21.5) |
| `measured_mA` | mA | burst average of 20 pulses × 8 ADC samples (14 bit, 10 Ω sense resistor) |
| `error_mA` | mA | effective_target_mA − measured_mA |
| `counter_applied` | counts | DAC command used for this burst |
| `counter_next` | counts | DAC command computed for the next burst |
| `p_term_counts`, `i_term_counts` | counts | proportional and integral terms |
| `command_limited`, `reference_limited` | 0 or 1 | command or reference was limited |
| `fault_code` | | NONE, ADC_RANGE or OVERCURRENT |
| `dt_ms` | ms | time since the previous controller update |

Early logs (`EarlyLog_*`) use an older format: `time_ms, burst, target_mA, measured_mA, error_mA, p_correction_counts, counter`.

**Note on `EarlyLog_3k_DAC_sweep_updated_graph.csv`:** it is labelled 3 kΩ, but it reaches 22.5 mA without a plateau and matches the 1 kΩ sweep, so it was almost certainly recorded on 1 kΩ.

### Oscilloscope exports
* **Rigol DHO924S** (`CommandDelay`): the header row gives the channel columns plus `t0` (start time, s) and `tInc` (sample interval, s). Values are volts. Firmware timing states, for reference: 0 idle, 1 positive DAC write, 2 ADC settling, 3 ADC acquisition, 4 baseline DAC write, 5 measurement finalisation, 6 controller, 7 CSV logging.
* **Two column exports** (`DefaultOutput`, `PulseDynamics`, files `*_CH1.csv` and `*_CH2.csv`): time (s) and voltage (V). CH1 is a GPIO sync line and CH2 the load voltage.
* **Large captures not included.** 36 oscilloscope exports over 50 MB (14.6 GB in total) are not in this repository: all 34 firmware timing captures (V4, 58 to 580 MB each, 16 ns sampling, CH1 load voltage and CH2 to CH4 GPIO state bits D5, D8 and A2; the state is b0 + 2·b1 + 4·b2) and two default output captures. They are available from the author on request. The script that analysed them is in `code/Oscilloscope_FirmwareTiming/`.

### Simulation outputs
CSV tables of per run metrics (RMSE in mA, settling times in s, switching rates in changes per second, command movement in counts) and MATLAB `.mat` files with time series. Column names are descriptive. Simulation 5 in the thesis is the Python implementation in `code/Simulation5_HardwareMatched/python/` (`simulation5.py`, `stats_core.py`). It reads Experiments 1, 2 and 3 from this release and writes `Simulation5_Python_RunLevel.csv` and `Simulation5_PlantCalibration_Python.csv`, which are included. Run it from the release root with `python code/Simulation5_HardwareMatched/python/simulation5.py --data . --out Simulation5_HardwareMatched` (numpy and pandas, a few minutes). The MATLAB Stage 2E outputs (`Stage2E_*.csv`) and `stage2E_run.m` are kept for comparison.

## Units
mA for current, counts for DAC commands (Counter; nominal 21.5 counts per mA), ms for logger time, s for simulation time, µs for pulse timing, V for oscilloscope channels.

## Firmware
The Arduino firmware is `code/firmware/OpenXstim_v1_3_TimingControllerDiagnostics.ino`. The same file was used for every experiment; only `CONTROL_MODE`, the gains `KP_COUNTS_PER_MA` and `KI_COUNTS_PER_MA_S`, and `ERROR_DEADBAND_MA` were changed between runs. The file holds the last settings used (faster PI, deadband 0.060 mA). Empirical PI: Kp 5.0, Ki 3.0; faster PI: Kp 4.867577, Ki 9.758558; deadband 0.030 mA except in Experiment 4.

## Running the scripts
The MATLAB scripts were written against the original working folders. Paths have been simplified: where a script defines a data folder, it now uses the folder the script is in, so put the CSV files in the same folder as the analysis file. Some scripts expect the original file names (for example `E03_R4000_PI_F_T01.csv`); `MANIFEST.csv` maps every release file back to its original name.

## Licence
* Data (every file outside `code/`): Creative Commons Attribution 4.0 International, see `LICENSE-DATA`.
* Code (analysis scripts, Simulink models and firmware in `code/`): BSD 3-Clause, see `LICENSE-CODE`.
