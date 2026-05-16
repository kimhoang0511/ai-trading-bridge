"""
Named Pipe server — single connection, handles all strategy IDs via sid field.
Runs on Windows. The pipe stays open as long as the EA is running.
"""

import json
import logging
import win32pipe
import win32file
import pywintypes

from config import PIPE_EA_TO_BRIDGE, PIPE_BRIDGE_TO_EA, PIPE_BUFFER_SIZE
from strategy import dispatch

log = logging.getLogger("bridge")


def _create_pipe(name: str, direction: str) -> int:
    """Create a named pipe in the specified direction."""
    if direction == "in":
        access = win32pipe.PIPE_ACCESS_INBOUND
    elif direction == "out":
        access = win32pipe.PIPE_ACCESS_OUTBOUND
    else:
        access = win32pipe.PIPE_ACCESS_DUPLEX

    return win32pipe.CreateNamedPipe(
        name,
        access,
        win32pipe.PIPE_TYPE_MESSAGE | win32pipe.PIPE_READMODE_MESSAGE | win32pipe.PIPE_WAIT,
        1,                  # max instances
        PIPE_BUFFER_SIZE,   # out buffer
        PIPE_BUFFER_SIZE,   # in buffer
        0,                  # default timeout
        None                # default security
    )


def run():
    """
    Main pipe server loop.
    Blocks until EA connects, then processes messages until EA disconnects.
    Loops back to wait for next EA connection.
    """
    log.info(f"Pipe server started")
    log.info(f"  IN  ← {PIPE_EA_TO_BRIDGE}")
    log.info(f"  OUT → {PIPE_BRIDGE_TO_EA}")
    log.info("Waiting for EA connection...")

    while True:
        pipe_in  = None
        pipe_out = None
        try:
            pipe_in  = _create_pipe(PIPE_EA_TO_BRIDGE, "in")
            pipe_out = _create_pipe(PIPE_BRIDGE_TO_EA, "out")

            # Block until EA connects to both pipes
            win32pipe.ConnectNamedPipe(pipe_in,  None)
            win32pipe.ConnectNamedPipe(pipe_out, None)
            log.info("EA connected!")

            # Message loop
            while True:
                # Read one message from EA
                try:
                    _, raw = win32file.ReadFile(pipe_in, PIPE_BUFFER_SIZE)
                except pywintypes.error as e:
                    # EA disconnected (error 109 = broken pipe)
                    log.info(f"EA disconnected ({e.args[1]})")
                    break

                # Parse JSON
                try:
                    data = json.loads(raw.decode("utf-8"))
                except json.JSONDecodeError as e:
                    log.error(f"JSON parse error: {e} | raw={raw[:100]}")
                    response = {"action": "NONE", "error": "invalid json"}
                else:
                    # Process message
                    response = dispatch(data)

                # Send response
                try:
                    out_bytes = json.dumps(response).encode("utf-8")
                    win32file.WriteFile(pipe_out, out_bytes)
                except pywintypes.error as e:
                    log.error(f"Write error: {e}")
                    break

        except pywintypes.error as e:
            log.error(f"Pipe error: {e}")

        finally:
            # Clean up handles
            for handle in [pipe_in, pipe_out]:
                if handle is not None:
                    try:
                        win32file.CloseHandle(handle)
                    except Exception:
                        pass

        log.info("Waiting for next EA connection...")
