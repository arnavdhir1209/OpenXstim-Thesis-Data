
#!/usr/bin/env python3

"""
OpenXstim P/PI Bench Controller Logger

Usage:
    python logger.py --list-ports
    python logger.py /dev/cu.usbmodem1101
    python logger.py /dev/cu.usbmodem1101 --no-plot
    python logger.py /dev/cu.usbmodem1101 --window 120
"""

import argparse
import csv
import math
import time

from collections import deque
from datetime import datetime
from pathlib import Path

import serial
from serial.tools import list_ports


# ============================================================
# SERIAL AND CSV CONFIGURATION
# ============================================================

BAUD_RATE = 115200

FIELDS = [
    "time_ms",
    "burst",
    "mode",
    "stim_state",
    "requested_mA",
    "effective_target_mA",
    "command_mA",
    "measured_mA",
    "error_mA",
    "counter_applied",
    "counter_next",
    "p_term_counts",
    "i_term_counts",
    "command_limited",
    "reference_limited",
    "fault_code",
    "dt_ms",
]


# ============================================================
# PARSE INCOMING ARDUINO DATA
# ============================================================

def parse_record(line):

    if not line.startswith("DATA,"):
        return None

    values = line.split(",")[1:]

    if len(values) != len(FIELDS):
        print("Ignoring malformed DATA line:", line)
        return None

    record = dict(zip(FIELDS, values))

    try:

        record["time_ms"] = int(record["time_ms"])
        record["burst"] = int(record["burst"])

        for key in [
            "requested_mA",
            "effective_target_mA",
            "command_mA",
            "p_term_counts",
            "i_term_counts",
            "dt_ms",
        ]:

            record[key] = float(record[key])

        # These can be blank during DISABLED or FAULT states.
        for key in [
            "measured_mA",
            "error_mA",
        ]:

            if record[key]:
                record[key] = float(record[key])
            else:
                record[key] = math.nan

        for key in [
            "counter_applied",
            "counter_next",
            "command_limited",
            "reference_limited",
        ]:

            record[key] = int(record[key])

        if record["mode"] not in {
            "OPEN_LOOP",
            "P_CONTROL",
            "PI_CONTROL",
        }:
            return None

        if record["stim_state"] not in {
            "RUNNING",
            "DISABLED",
            "FAULT_LATCHED",
        }:
            return None

        for key in [
            "requested_mA",
            "effective_target_mA",
            "command_mA",
            "p_term_counts",
            "i_term_counts",
            "dt_ms",
        ]:

            if not math.isfinite(record[key]):
                return None

    except ValueError:

        print("Ignoring invalid DATA line:", line)
        return None

    return record


# ============================================================
# MAIN LOGGER
# ============================================================

def main():

    parser = argparse.ArgumentParser(
        description="OpenXstim P/PI live CSV logger"
    )

    parser.add_argument(
        "port",
        nargs="?",
        help="Arduino serial port"
    )

    parser.add_argument(
        "--baud",
        type=int,
        default=BAUD_RATE
    )

    parser.add_argument(
        "--window",
        type=float,
        default=60.0
    )

    parser.add_argument(
        "--no-plot",
        action="store_true"
    )

    parser.add_argument(
        "--list-ports",
        action="store_true"
    )

    args = parser.parse_args()

    if args.list_ports:

        for p in list_ports.comports():
            print(p.device, "-", p.description)

        return

    if not args.port:

        parser.error(
            "Provide a serial port or use --list-ports"
        )

    if args.window <= 0:

        parser.error(
            "--window must be positive"
        )

    # ========================================================
    # CREATE TIMESTAMPED CSV
    # ========================================================

    output_dir = (
        Path(__file__).resolve().parent / "recordings"
    )

    output_dir.mkdir(
        parents=True,
        exist_ok=True
    )

    timestamp = datetime.now().strftime(
        "%Y%m%d_%H%M%S_%f"
    )

    filename = output_dir / (
        f"OpenXstim_{timestamp}.csv"
    )

    # Buffers only retain data within the live plot window.
    channels = {
        key: deque()
        for key in [
            "t",
            "requested",
            "target",
            "measured",
            "error",
            "applied",
            "next",
            "limited",
            "reference_limited",
            "fault",
        ]
    }

    # ========================================================
    # CREATE LIVE PLOTS
    # ========================================================

    plt = None

    if not args.no_plot:

        import matplotlib.pyplot as plt

        plt.ion()

        fig, axes = plt.subplots(
            3,
            1,
            sharex=True,
            figsize=(11, 8)
        )

        ax_current, ax_error, ax_counter = axes

        target_line, = ax_current.plot(
            [],
            [],
            "--",
            label="Effective target"
        )

        requested_line, = ax_current.plot(
            [],
            [],
            ":",
            label="Requested"
        )

        current_line, = ax_current.plot(
            [],
            [],
            label="Measured"
        )

        error_line, = ax_error.plot(
            [],
            [],
            label="Active tracking error"
        )

        ax_error.axhline(
            0,
            linestyle=":",
            color="gray"
        )

        applied_line, = ax_counter.plot(
            [],
            [],
            label="Applied counter"
        )

        next_line, = ax_counter.plot(
            [],
            [],
            "--",
            label="Next counter"
        )

        limited_line, = ax_counter.plot(
            [],
            [],
            "rx",
            label="Command limited"
        )

        fault_line, = ax_counter.plot(
            [],
            [],
            "ks",
            label="Fault latched"
        )

        ax_current.set_ylabel("Current (mA)")
        ax_error.set_ylabel("Error (mA)")

        ax_counter.set_ylabel("DAC offset (counts)")
        ax_counter.set_xlabel(
            "Time since logging began (s)"
        )

        for ax in axes:
            ax.grid(True)
            ax.legend(loc="best")

        fig.tight_layout()
        plt.show(block=False)

    # ========================================================
    # ACQUISITION STATE
    # ========================================================

    first_time_ms = None
    previous_time_ms = None

    rows_saved = 0

    latest_mode = "UNKNOWN"
    latest_state = "UNKNOWN"

    last_redraw = time.monotonic()

    print("=" * 50)
    print("OpenXstim P/PI Controller Logger")
    print("=" * 50)

    print("Port:", args.port)
    print("CSV:", filename)
    print("Live plot:", not args.no_plot)
    print()
    print("Press Ctrl+C to stop.")
    print()

    try:

        with serial.Serial(
            args.port,
            args.baud,
            timeout=0.05
        ) as ser:

            with filename.open(
                "w",
                newline="",
                encoding="utf-8"
            ) as file:

                writer = csv.writer(file)

                writer.writerow(FIELDS)
                file.flush()

                while True:

                    raw = ser.readline()

                    if raw:

                        line = raw.decode(
                            "utf-8",
                            errors="replace"
                        ).strip()

                        record = parse_record(line)

                        if record is not None:

                            # Preserve original CSV text,
                            # including intentionally blank fields.
                            values = line.split(",")[1:]

                            writer.writerow(values)
                            file.flush()

                            rows_saved += 1

                            time_ms = record["time_ms"]

                            # Handle Arduino reset or millis rollover.
                            if (
                                first_time_ms is None
                                or (
                                    previous_time_ms is not None
                                    and time_ms < previous_time_ms
                                )
                            ):

                                first_time_ms = time_ms

                                for series in channels.values():
                                    series.clear()

                                if previous_time_ms is not None:
                                    print(
                                        "Arduino clock reset detected."
                                    )

                            previous_time_ms = time_ms

                            time_s = (
                                time_ms - first_time_ms
                            ) / 1000.0

                            latest_mode = record["mode"]
                            latest_state = record["stim_state"]

                            # Add samples to plot buffers.
                            new_values = {

                                "t": time_s,

                                "requested":
                                    record["requested_mA"],

                                "target":
                                    record["effective_target_mA"],

                                "measured":
                                    record["measured_mA"],

                                "error":
                                    record["error_mA"],

                                "applied":
                                    record["counter_applied"],

                                "next":
                                    record["counter_next"],

                                "limited":
                                    record["command_limited"],

                                "reference_limited":
                                    record["reference_limited"],

                                "fault":
                                    int(
                                        record["stim_state"]
                                        == "FAULT_LATCHED"
                                    ),
                            }

                            for key, value in new_values.items():
                                channels[key].append(value)

                            # Trim display history only.
                            # The CSV retains the full recording.
                            while (
                                channels["t"]
                                and (
                                    time_s - channels["t"][0]
                                    > args.window
                                )
                            ):

                                for series in channels.values():
                                    series.popleft()

                            warning = ""

                            if record["stim_state"] == "FAULT_LATCHED":

                                warning += (
                                    " [FAULT: "
                                    + record["fault_code"]
                                    + "]"
                                )

                            if record["command_limited"]:
                                warning += " [DAC LIMITED]"

                            if record["reference_limited"]:
                                warning += " [REFERENCE LIMITED]"

                            print(
                                f"Burst {record['burst']:5d} | "
                                f"{latest_mode:10s} | "
                                f"{latest_state:13s} | "
                                f"Requested "
                                f"{record['requested_mA']:.2f} | "
                                f"Target "
                                f"{record['effective_target_mA']:.2f} | "
                                f"Measured "
                                f"{record['measured_mA']:.3f} | "
                                f"DAC "
                                f"{record['counter_applied']} -> "
                                f"{record['counter_next']}"
                                f"{warning}"
                            )

                    # =================================================
                    # LIVE GRAPH REFRESH
                    # =================================================

                    if plt is not None:

                        if not plt.fignum_exists(fig.number):

                            print("Plot window closed.")
                            break

                        now = time.monotonic()

                        if (
                            now - last_redraw >= 0.2
                            and channels["t"]
                        ):

                            x = list(channels["t"])

                            target_line.set_data(
                                x,
                                list(channels["target"])
                            )

                            requested_line.set_data(
                                x,
                                list(channels["requested"])
                            )

                            current_line.set_data(
                                x,
                                list(channels["measured"])
                            )

                            error_line.set_data(
                                x,
                                list(channels["error"])
                            )

                            applied_line.set_data(
                                x,
                                list(channels["applied"])
                            )

                            next_line.set_data(
                                x,
                                list(channels["next"])
                            )

                            limited_x = [
                                t
                                for t, flag in zip(
                                    x,
                                    channels["limited"]
                                )
                                if flag
                            ]

                            limited_y = [
                                y
                                for y, flag in zip(
                                    channels["next"],
                                    channels["limited"]
                                )
                                if flag
                            ]

                            limited_line.set_data(
                                limited_x,
                                limited_y
                            )

                            fault_x = [
                                t
                                for t, flag in zip(
                                    x,
                                    channels["fault"]
                                )
                                if flag
                            ]

                            fault_y = [
                                y
                                for y, flag in zip(
                                    channels["next"],
                                    channels["fault"]
                                )
                                if flag
                            ]

                            fault_line.set_data(
                                fault_x,
                                fault_y
                            )

                            ax_current.set_title(
                                f"OpenXstim | "
                                f"{latest_mode} | "
                                f"{latest_state}"
                            )

                            for ax in axes:
                                ax.relim()
                                ax.autoscale_view()

                            fig.canvas.draw_idle()

                            last_redraw = now

                        plt.pause(0.001)

    except KeyboardInterrupt:

        print("\nLogging stopped by user.")

    except serial.SerialException as exc:

        print("Serial connection error:", exc)

    finally:

        if plt is not None:
            plt.close(fig)

        print()
        print("Rows saved:", rows_saved)
        print("CSV file:", filename)


if __name__ == "__main__":
    main()
