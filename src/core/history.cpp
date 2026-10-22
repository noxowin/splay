#include "history.hpp"
#include <algorithm>
#include <atomic>
#include <fstream>
#include <filesystem>
#include <stdexcept>
#include <windows.h>

namespace splay {
namespace {
const char* fields[] = {"host", "port", "username", "room", "tls"};
Json empty() {
    Json value={{"schema",1},{"last",Json::object()},{"profiles",Json::array()},{"values",Json::object()},{"preferences",Json::object()}};
    for(const auto field:fields)value["values"][field]=Json::array();
    return value;
}
std::wstring wide(const std::string& input) {
    if(input.empty()||input.find('\0')!=std::string::npos)throw std::runtime_error("History path is empty or invalid");
    const auto size=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,input.data(),static_cast<int>(input.size()),nullptr,0);
    if(!size)throw std::runtime_error("History path must be UTF-8");
    std::wstring result(size,L'\0');
    MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,input.data(),static_cast<int>(input.size()),result.data(),size);
    return result;
}
struct Handle {
    HANDLE value=INVALID_HANDLE_VALUE;
    ~Handle(){if(value!=INVALID_HANDLE_VALUE)CloseHandle(value);}
};
struct Lock {
    Handle file;
    OVERLAPPED overlap{};
    explicit Lock(const std::wstring& path) {
        file.value=CreateFileW((path+L".lock").c_str(),GENERIC_READ|GENERIC_WRITE,
            FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(file.value==INVALID_HANDLE_VALUE)throw std::runtime_error("Cannot open history lock file");
        const auto start=GetTickCount64();
        while(!LockFileEx(file.value,LOCKFILE_EXCLUSIVE_LOCK|LOCKFILE_FAIL_IMMEDIATELY,0,1,0,&overlap)) {
            if(GetLastError()!=ERROR_LOCK_VIOLATION||GetTickCount64()-start>=1900)
                throw std::runtime_error("History file is busy or cannot be locked; try again");
            Sleep(10);
        }
    }
    ~Lock(){if(file.value!=INVALID_HANDLE_VALUE)UnlockFileEx(file.value,0,1,0,&overlap);}
};
Json settings(const Json& source,bool allow_empty_room=false) {
    if(!source.is_object())throw std::runtime_error("History settings must be an object");
    Json result=Json::object();
    for(const auto key:fields) {
        if(!source.contains(key))throw std::runtime_error(std::string("Missing history field: ")+key);
        const auto& value=source[key];
        if(std::string(key)=="port") {
            if(!value.is_number_integer()||value.get<long long>()<1||value.get<long long>()>65535)
                throw std::runtime_error("Invalid history port");
        } else {
            if(!value.is_string())throw std::runtime_error(std::string("Invalid history field: ")+key);
            const auto text=value.get<std::string>();
            if((text.empty()&&!(allow_empty_room&&std::string(key)=="room"))||text.size()>1024||std::any_of(text.begin(),text.end(),[](unsigned char c){return c<32||c==127;}))
                throw std::runtime_error(std::string("Invalid history field: ")+key);
            if(std::string(key)=="tls"&&text!="prefer"&&text!="require"&&text!="off")throw std::runtime_error("Invalid history TLS policy");
        }
        result[key]=value;
    }
    return result;
}
Json preferences(const Json& source) {
    if(!source.is_object())throw std::runtime_error("History preferences must be an object");
    Json result=Json::object();
    for(auto it=source.begin();it!=source.end();++it) {
        const auto& key=it.key();
        if(key=="chat_mode") {
            if(!it.value().is_string()||(it.value()!="room"&&it.value()!="danmaku"))
                throw std::runtime_error("Invalid chat mode preference");
        } else if(key=="pause_on_leave"||key=="pause_on_join") {
            if(!it.value().is_boolean())throw std::runtime_error("Invalid room pause preference");
        } else throw std::runtime_error("Unknown history preference: "+key);
        result[key]=it.value();
    }
    return result;
}
void append(Json& list,const Json& value) {
    if(std::find(list.begin(),list.end(),value)==list.end())list.push_back(value);
}
std::string display_name(const Json& value) {
    if(!value.is_string())throw std::runtime_error("Invalid history name");
    const auto name=value.get<std::string>();
    if(name.empty()||name.size()>1024||std::any_of(name.begin(),name.end(),[](unsigned char c){return c<32||c==127;}))
        throw std::runtime_error("Invalid history name");
    return name;
}
bool same_settings(const Json& left,const Json& right) {
    for(const auto key:fields)if(left.at(key)!=right.at(key))return false;
    return true;
}
void remember_profile(Json& profiles,const Json& profile) {
    for(auto& item:profiles)if(same_settings(item,profile))return;
    profiles.push_back(profile);
}
void remember_values(Json& value,const Json& profile) {
    for(const auto key:fields) {
        if(std::string(key)=="room"&&profile[key]=="")continue;
        append(value["values"][key],profile[key]);
    }
}
Json read(const std::wstring& path) {
    const auto attributes=GetFileAttributesW(path.c_str());
    if(attributes==INVALID_FILE_ATTRIBUTES) {
        if(GetLastError()==ERROR_FILE_NOT_FOUND)return empty();
        throw std::runtime_error("Cannot read history file");
    }
    std::ifstream file(std::filesystem::path(path),std::ios::binary);
    if(!file)throw std::runtime_error("Cannot read history file");
    Json source;
    try {file>>source;}catch(...) {throw std::runtime_error("History file is damaged; original file preserved");}
    if(!file.eof()) {file>>std::ws;if(!file.eof())throw std::runtime_error("History file contains trailing data; original file preserved");}
    try {
        if(!source.is_object()||source.at("schema")!=1||!source.at("profiles").is_array()||!source.at("last").is_object())throw std::runtime_error("schema");
        Json result=empty();
        if(source.contains("preferences"))result["preferences"]=preferences(source["preferences"]);
        if(!source["last"].empty())result["last"]=settings(source["last"],true);
        for(const auto& item:source["profiles"]) {
            auto profile=settings(item);
            if(item.contains("name"))profile["name"]=display_name(item["name"]);
            remember_profile(result["profiles"],profile);
        }
        if(source.contains("values")) {
            if(!source["values"].is_object())throw std::runtime_error("values");
            for(const auto key:fields)if(source["values"].contains(key)) {
                if(!source["values"][key].is_array())throw std::runtime_error("values");
                for(const auto& item:source["values"][key]) {
                    // Validate individual historical values using a complete valid sample.
                    Json sample={{"host","syncplay.pl"},{"port",8999},{"username","splayuser"},{"room","default"},{"tls","prefer"}};
                    sample[key]=item;settings(sample);append(result["values"][key],item);
                }
            }
        }
        // Explicit values (including empty lists) are authoritative. Only old
        // schema 1 files without values need suggestions derived from settings.
        if(!source.contains("values")) {
            for(const auto& item:result["profiles"])remember_values(result,item);
            if(!result["last"].empty())remember_values(result,result["last"]);
        }
        return result;
    }catch(...) {throw std::runtime_error("History file has invalid fields; original file preserved");}
}
void write(const std::wstring& path,const Json& value) {
    static std::atomic<unsigned> serial{0};
    const auto temp=path+L".tmp-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(++serial);
    try {
        const auto bytes=value.dump(2)+"\n";
        {
            Handle file;
            file.value=CreateFileW(temp.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
            if(file.value==INVALID_HANDLE_VALUE)throw std::runtime_error("Cannot create history temporary file; previous file preserved");
            size_t offset=0;
            while(offset<bytes.size()) {
                DWORD written=0;
                const auto count=static_cast<DWORD>(std::min<size_t>(bytes.size()-offset,1u<<20));
                if(!WriteFile(file.value,bytes.data()+offset,count,&written,nullptr)||written==0)
                    throw std::runtime_error("Cannot write history file; previous file preserved");
                offset+=written;
            }
            if(!FlushFileBuffers(file.value))throw std::runtime_error("Cannot flush history file; previous file preserved");
        }
        const auto exists=GetFileAttributesW(path.c_str())!=INVALID_FILE_ATTRIBUTES;
        const bool ok=exists?ReplaceFileW(path.c_str(),temp.c_str(),nullptr,0,nullptr,nullptr)!=0:
            MoveFileExW(temp.c_str(),path.c_str(),MOVEFILE_WRITE_THROUGH)!=0;
        if(!ok)throw std::runtime_error("Cannot replace history file; previous file preserved");
    }catch(...) {DeleteFileW(temp.c_str());throw;}
}
}
Json History::handle(const Json& command) {
    Json result=empty();
    try {
        const auto action=command.at("action").get<std::string>();
        if(action=="history-load") {
            auto candidate=command.at("path").get<std::string>();
            wide(candidate);
            path_=std::move(candidate);
        } else if(action!="history-save"&&action!="history-rename"&&action!="history-delete"&&
                  action!="history-clear-values"&&action!="history-clear"&&action!="history-preferences")throw std::runtime_error("Unknown history command");
        const auto remember=action=="history-save"&&command.value("remember_profile",false);
        Json draft;
        if(action=="history-save")draft=settings(command.at("settings"),!remember);
        if(action=="history-preferences")draft=preferences(command.at("preferences"));
        if(action=="history-rename"||action=="history-delete")draft=settings(command.at("settings"));
        std::string name,field;
        if(action=="history-rename")name=display_name(command.at("name"));
        if(action=="history-clear-values") {
            field=command.at("field").get<std::string>();
            if(std::none_of(std::begin(fields),std::end(fields),[&](const char* key){return field==key;}))
                throw std::runtime_error("Invalid history suggestion field");
        }
        const auto path=wide(path_);
        Lock lock(path);
        result=read(path);
        if(action=="history-save") {
            auto next=result;
            next["last"]=std::move(draft);
            if(remember)remember_profile(next["profiles"],next["last"]);
            remember_values(next,next["last"]);
            write(path,next);
            result=std::move(next);
        } else if(action!="history-load") {
            auto next=result;
            if(action=="history-clear") {
                next=empty();
                next["preferences"]=result["preferences"];
            }
            else if(action=="history-preferences") {
                // Re-read under the shared lock, then merge only supplied keys.
                // Preferences never modify connection profiles or credentials.
                for(auto it=draft.begin();it!=draft.end();++it)next["preferences"][it.key()]=it.value();
            }
            else if(action=="history-clear-values")next["values"][field]=Json::array();
            else if(action=="history-delete") {
                auto& profiles=next["profiles"];
                profiles.erase(std::remove_if(profiles.begin(),profiles.end(),[&](const Json& profile){return same_settings(profile,draft);}),profiles.end());
                if(!next["last"].empty()&&same_settings(next["last"],draft))next["last"]=Json::object();
            } else {
                bool found=false;
                for(auto& profile:next["profiles"])if(same_settings(profile,draft)) {
                    profile["name"]=name;found=true;
                }
                if(!found)throw std::runtime_error("History profile does not exist");
            }
            write(path,next);
            result=std::move(next);
        }
    }catch(const std::exception& error) {result["error"]=error.what();}
    if(command.is_object()&&command.contains("request_id"))result["request_id"]=command["request_id"];
    return result;
}
}
