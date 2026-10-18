"""Exercise only a child test process's native password window, never an existing mpv."""
from pathlib import Path
import argparse
import ctypes as c
from ctypes import wintypes as w
import os
import queue
import shutil
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--compiler', default=os.environ.get('CXX') or shutil.which('g++') or r'C:\Program Files\mingw64\bin\g++.exe')
opts = parser.parse_args()
if os.name != 'nt':
    raise SystemExit('This native Windows dialog test requires Windows')
work = ROOT / '.local/integration/secret-input-native'
work.mkdir(parents=True, exist_ok=True)
harness = work / 'native.cpp'
harness.write_text(r'''
#include "mpv/secret_input.hpp"
#include <chrono>
#include <iostream>
#include <sstream>
#include <thread>
#include <windows.h>
int main() {
    splay::SecretInput input;
    std::string line;
    while (std::getline(std::cin,line)) {
        std::istringstream command(line); std::string action; unsigned long long id=0;
        command>>action>>id;
        if (action=="request") {
            input.request(id,"splay secret test "+std::to_string(id),u8"合成测试密码；不会写入 mpv 输入历史。");
            std::cout<<"ACK "<<id<<std::endl;
        } else if (action=="cancel") { input.cancel(); std::cout<<"CANCELLED"<<std::endl; }
        else if (action=="quit") break;
        else if (action=="poll") {
            bool found=false;
            for (int i=0;i<100;++i) {
                if (auto value=input.poll()) {
                    const bool matches=value->value==u8"合成Splay_Only_42";
                    std::cout<<"RESULT "<<value->id<<" "<<value->cancelled<<" "<<value->value.size()<<" "
                        <<(!value->error.empty())<<" "<<matches<<std::endl;
                    if(!value->value.empty()) SecureZeroMemory(value->value.data(),value->value.size());
                    value->value.clear(); found=true; break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            if (!found) std::cout<<"NONE"<<std::endl;
        }
    }
}
''', encoding='utf-8')
exe = work / 'native.exe'
subprocess.run([opts.compiler, '-std=c++17', '-O2', '-Wall', '-Wextra', '-static', '-pthread',
                '-DNOMINMAX', '-I'+str(ROOT/'src'), str(harness), str(ROOT/'src/mpv/secret_input.cpp'),
                '-o', str(exe), '-luser32', '-lgdi32'], check=True, cwd=ROOT)

user = c.WinDLL('user32', use_last_error=True)
enum_type = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
user.EnumWindows.argtypes = [enum_type, w.LPARAM]
user.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
user.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
user.GetWindowTextW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
user.GetDlgItem.argtypes = [w.HWND, c.c_int]
user.GetDlgItem.restype = w.HWND
user.GetWindowLongPtrW.argtypes = [w.HWND, c.c_int]
user.GetWindowLongPtrW.restype = c.c_ssize_t
user.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
user.SendMessageW.restype = c.c_ssize_t
user.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
user.SetWindowTextW.argtypes = [w.HWND, w.LPCWSTR]
user.IsWindow.argtypes = [w.HWND]
proc = subprocess.Popen([str(exe)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW)
output = queue.Queue()
logs = []
def consume():
    for line in proc.stdout:
        logs.append(line)
        output.put(line.strip())
threading.Thread(target=consume, daemon=True).start()

def command(text, expected=None):
    proc.stdin.write(text+'\n'); proc.stdin.flush()
    if expected is not None:
        result = output.get(timeout=5)
        assert result == expected, result

def result_for(number, expected):
    for _ in range(5):
        command('poll')
        result=output.get(timeout=5)
        if result == expected: return
        if result == 'NONE': continue
        parts=result.split()
        assert parts[0]=='RESULT' and int(parts[1])<number and parts[2:] == ['1','0','0','0'], result
    raise AssertionError('No matching result: '+str(number))

def set_text(edit,text):
    buffer=c.create_unicode_buffer(text)
    assert user.SendMessageW(edit,0xC,0,c.cast(buffer,c.c_void_p).value), 'WM_SETTEXT failed'

def window(number):
    deadline = time.monotonic()+5
    while time.monotonic() < deadline:
        found = []
        @enum_type
        def visit(hwnd, _):
            pid=w.DWORD()
            user.GetWindowThreadProcessId(hwnd, c.byref(pid))
            if pid.value == proc.pid:
                kind=c.create_unicode_buffer(100); title=c.create_unicode_buffer(200)
                user.GetClassNameW(hwnd, kind, len(kind)); user.GetWindowTextW(hwnd, title, len(title))
                if kind.value == 'splay.SecretInput' and title.value == 'splay secret test '+str(number):
                    found.append(hwnd)
            return True
        user.EnumWindows(visit, 0)
        if found:
            edit=user.GetDlgItem(found[0],1001)
            if edit: return found[0],edit
        time.sleep(.02)
    raise AssertionError('Isolated password window did not appear: '+str(number))

try:
    command('request 1','ACK 1')
    hwnd,edit=window(1)
    assert user.GetWindowLongPtrW(edit,-16) & 0x20, 'Password EDIT must have ES_PASSWORD'
    assert user.SendMessageW(edit,0xD2,0,0) != 0, 'Password masking character must be enabled'
    assert user.SendMessageW(edit,0xD5,0,0) == 1024, 'Input length must be bounded'
    set_text(edit,'合成Splay_Only_42')
    user.PostMessageW(edit,0x100,0x0D,0)
    result_for(1,'RESULT 1 0 19 0 1')
    command('request 2','ACK 2'); hwnd,edit=window(2)
    set_text(edit,'CANCELLED_SYNTHETIC')
    user.PostMessageW(edit,0x100,0x1B,0)
    result_for(2,'RESULT 2 1 0 0 0')
    command('request 3','ACK 3'); hwnd,edit=window(3)
    user.PostMessageW(hwnd,0x10,0,0)
    result_for(3,'RESULT 3 1 0 0 0')
    command('request 4','ACK 4'); hwnd,edit=window(4)
    set_text(edit,'REPLACED_SYNTHETIC')
    command('request 5','ACK 5'); hwnd,edit=window(5)
    # The old result may already have been delivered or be pending. It must never
    # be identified as request 5 or carry the abandoned value.
    command('poll')
    assert output.get(timeout=5) in ('RESULT 4 1 0 0 0','NONE')
    set_text(edit,'合成Splay_Only_42'); user.PostMessageW(edit,0x100,0x0D,0)
    result_for(5,'RESULT 5 0 19 0 1')
    command('request 6','ACK 6'); window(6)
    command('cancel','CANCELLED'); command('poll')
    assert output.get(timeout=5) in ('RESULT 6 1 0 0 0','NONE')
    command('request 7','ACK 7'); hwnd,edit=window(7)
    set_text(edit,'你'*400)  # 1200 UTF-8 bytes; rejected, never returned.
    user.PostMessageW(edit,0x100,0x0D,0)
    result_for(7,'RESULT 7 0 0 1 0')
    command('request 8','ACK 8'); hwnd,edit=window(8)
    command('quit')
    proc.wait(timeout=5)
    assert proc.returncode == 0, 'Worker must stop safely with a dialog open'
    assert not user.IsWindow(hwnd)
    combined=''.join(logs)
    for secret in ('合成Splay_Only_42','CANCELLED_SYNTHETIC','REPLACED_SYNTHETIC'):
        assert secret not in combined, 'Native output must contain no passwords'
    print('SECRET_INPUT_NATIVE_PASSED masking, Unicode, Enter/Esc/close, bounded length, replacement, cancel, shutdown, no secret output')
finally:
    if proc.poll() is None:
        proc.kill();proc.wait(timeout=5)
