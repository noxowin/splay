#pragma once
#include <stdexcept>
#include <string>
#include <windows.h>

namespace splay {
    // Exclusive cross-process lock on "<path>.lock", shared by the history
    // and credential stores of every player process.
    //
    // The request waits in the system's queue for that file, so processes are
    // served in turn. Polling with a sleep let later arrivals take the lock
    // first, and under contention an early one could time out while the file
    // was never held for long. The wait is still bounded: the caller is the
    // plugin's event loop.
    class FileLock {
    public:
        FileLock(const std::wstring& path,const char* open_error,const char* busy_error,DWORD timeout_ms=5000) {
            file_=CreateFileW((path+L".lock").c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,
                nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OVERLAPPED,nullptr);
            if(file_==INVALID_HANDLE_VALUE)throw std::runtime_error(open_error);
            event_=CreateEventW(nullptr,TRUE,FALSE,nullptr);
            if(event_){
                OVERLAPPED request{};
                request.hEvent=event_;
                if(LockFileEx(file_,LOCKFILE_EXCLUSIVE_LOCK,0,1,0,&request))held_=true;
                else if(GetLastError()==ERROR_IO_PENDING){
                    if(WaitForSingleObject(event_,timeout_ms)!=WAIT_OBJECT_0)CancelIoEx(file_,&request);
                    // Wait for the request to settle either way: a lock granted
                    // while it was being cancelled is kept, not leaked.
                    DWORD ignored=0;
                    held_=GetOverlappedResult(file_,&request,&ignored,TRUE)!=0;
                }
            }
            if(!held_){
                close();
                throw std::runtime_error(busy_error);
            }
        }
        ~FileLock(){
            OVERLAPPED range{};
            UnlockFileEx(file_,0,1,0,&range);
            close();
        }
        FileLock(const FileLock&)=delete;
        FileLock& operator=(const FileLock&)=delete;
    private:
        void close(){
            if(event_)CloseHandle(event_);
            if(file_!=INVALID_HANDLE_VALUE)CloseHandle(file_);
            event_=nullptr;file_=INVALID_HANDLE_VALUE;
        }
        HANDLE file_=INVALID_HANDLE_VALUE,event_=nullptr;
        bool held_=false;
    };
}
