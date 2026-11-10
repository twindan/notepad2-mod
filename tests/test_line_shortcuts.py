"""Current-line shortcuts use existing Scintilla actions, without a new subsystem."""
import ctypes
import pythoncom
import pytest
import win32clipboard
from pywinauto.timings import wait_until, wait_until_passes


def clipboard_text(value=None):
    def access():
        win32clipboard.OpenClipboard()
        try:
            if value is None:
                return win32clipboard.GetClipboardData(win32clipboard.CF_UNICODETEXT)
            win32clipboard.EmptyClipboard()
            win32clipboard.SetClipboardText(value, win32clipboard.CF_UNICODETEXT)
        finally:
            win32clipboard.CloseClipboard()
    return wait_until_passes(5, 0.05, access)


@pytest.fixture(autouse=True)
def preserve_clipboard():
    # OLE retains the original data object, including non-text formats.
    pythoncom.OleInitialize()
    original = wait_until_passes(5, 0.05, pythoncom.OleGetClipboard)
    try:
        clipboard_text("np2-test-sentinel")
        yield
    finally:
        try:
            wait_until_passes(5, 0.05, lambda: pythoncom.OleSetClipboard(original))
            wait_until_passes(5, 0.05, pythoncom.OleFlushClipboard)
        finally:
            ctypes.windll.ole32.OleUninitialize()


@pytest.mark.parametrize("eol", [b"\r\n", b"\n", b"\r"])
@pytest.mark.parametrize("last", [False, True])
@pytest.mark.parametrize("keys", ["^c", "^{INSERT}"])
def test_ctrl_c_copies_line_without_selection(editor_factory, eol, last, keys):
    content = b"first" + eol + "βeta".encode()
    with editor_factory(named=True, content=content) as e:
        e.sci(2031, {b"\r\n": 0, b"\r": 1, b"\n": 2}[eol])
        position = len(b"first" + eol) + 2 if last else 2
        e.sci(2160, position, position)
        before, undo = e.read_bytes(), e.sci(2174)
        e.editor.send_keystrokes(keys)
        expected = ("βeta" if last else "first") + eol.decode()
        wait_until(5, 0.05, lambda: clipboard_text() == expected)
        assert e.read_bytes() == before
        assert e.sci(2008) == e.sci(2009) == position
        assert e.sci(2174) == undo


@pytest.mark.parametrize("selection", [False, True])
@pytest.mark.parametrize("keys", ["^x", "+{DELETE}"])
def test_shift_delete_cuts_line_or_selection_and_undoes(editor_factory, selection, keys):
    original = b"first\r\nsecond\r\nthird"
    with editor_factory(named=True, content=original) as e:
        e.sci(2160, 1 if selection else 2, 4 if selection else 2)
        e.editor.send_keystrokes(keys)
        expected = b"ft\r\nsecond\r\nthird" if selection else b"second\r\nthird"
        wait_until(5, 0.05, lambda: e.read_bytes() == expected)
        assert clipboard_text() == ("irs" if selection else "first\r\n")
        e.sci(2176)
        assert e.read_bytes() == original


def test_ctrl_c_keeps_selected_text_behavior(editor_factory):
    with editor_factory(named=True, content=b"first\r\nsecond") as e:
        e.sci(2160, 1, 4)
        e.editor.send_keystrokes("^c")
        wait_until(5, 0.05, lambda: clipboard_text() == "irs")
        assert e.read_bytes() == b"first\r\nsecond"


def test_read_only_cut_preserves_text_and_clipboard(editor_factory):
    with editor_factory(named=True, content=b"read only\r\n") as e:
        e.sci(2171, 1)
        e.command(40302)
        assert e.read_bytes() == b"read only\r\n"
        assert clipboard_text() == "np2-test-sentinel"


@pytest.mark.parametrize("original,position,remaining,copied", [
    (b"last", 2, b"", "last\r\n"),
    (b"first\r\nlast", 9, b"first\r\n", "last\r\n"),
    (b"first\r\n\r\nthird", 7, b"first\r\nthird", "\r\n"),
])
def test_cut_line_edges(editor_factory, original, position, remaining, copied):
    with editor_factory(named=True, content=original) as e:
        e.sci(2160, position, position)
        e.editor.send_keystrokes("+{DELETE}")
        wait_until(5, 0.05, lambda: e.read_bytes() == remaining)
        assert clipboard_text() == copied
        e.sci(2176)
        assert e.read_bytes() == original


def test_empty_cut_does_not_replace_clipboard(editor_factory):
    with editor_factory() as e:
        e.command(40302)
        assert e.read_bytes() == b""
        assert clipboard_text() == "np2-test-sentinel"


@pytest.mark.parametrize("copy_keys", ["^c", "^{INSERT}", "^x", "+{DELETE}"])
@pytest.mark.parametrize("paste_keys", ["^v", "+{INSERT}"])
def test_line_clipboard_pastes_above_current_line(editor_factory, copy_keys, paste_keys):
    original = b"first\r\nsecond\r\nthird"
    cutting = copy_keys in ("^x", "+{DELETE}")
    with editor_factory(named=True, content=original) as e:
        e.sci(2160, 2, 2)
        e.editor.send_keystrokes(copy_keys)
        wait_until(5, 0.05, lambda: clipboard_text() == "first\r\n")
        marker = win32clipboard.RegisterClipboardFormat("MSDEVLineSelect")
        assert win32clipboard.IsClipboardFormatAvailable(marker)
        # Paste while the caret is inside 'third', not at column zero.
        before_paste = b"second\r\nthird" if cutting else original
        caret = len(before_paste) - 2
        e.sci(2160, caret, caret)
        e.editor.send_keystrokes(paste_keys)
        expected = b"second\r\nfirst\r\nthird" if cutting else b"first\r\nsecond\r\nfirst\r\nthird"
        wait_until(5, 0.05, lambda: e.read_bytes() == expected)
        e.sci(2176)
        assert e.read_bytes() == before_paste
