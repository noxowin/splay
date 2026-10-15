#include "credentials.hpp"
#include <algorithm>
#include <atomic>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <vector>
#include <windows.h>
#include <dpapi.h>

namespace splay {
namespace {
using Json=nlohmann::json;
constexpr size_t max_file=4u*1024u*1024u,max_entries=256,max_blob_hex=16384;
Json empty(){return {{"schema",1},{"entries",Json::array()}};}
std::wstring wide(const std::string& input) {
    if(input.empty()||input.size()>32767||input.find('\0')!=input.npos)throw std::runtime_error("Credential path is empty or invalid");
    const auto size=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,input.data(),static_cast<int>(input.size()),nullptr,0);
    if(!size)throw std::runtime_error("Credential path must be UTF-8");
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
        file.value=CreateFileW((path+L".lock").c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,
            nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(file.value==INVALID_HANDLE_VALUE)throw std::runtime_error("Cannot open credential lock file");
        const auto start=GetTickCount64();
        while(!LockFileEx(file.value,LOCKFILE_EXCLUSIVE_LOCK|LOCKFILE_FAIL_IMMEDIATELY,0,1,0,&overlap)) {
            if(GetLastError()!=ERROR_LOCK_VIOLATION||GetTickCount64()-start>=1900)
                throw std::runtime_error("Credential file is busy or cannot be locked; try again");
            Sleep(10);
        }
    }
    ~Lock(){if(file.value!=INVALID_HANDLE_VALUE)UnlockFileEx(file.value,0,1,0,&overlap);}
};
int port_number(const Json& value) {
    if(!value.is_number_integer())throw std::runtime_error("Invalid credential port");
    // Check before converting, including unsigned JSON integers outside int64 range.
    if(value<1||value>65535)throw std::runtime_error("Invalid credential port");
    return value.get<int>();
}
std::string host_text(const Json& value) {
    if(!value.is_string())throw std::runtime_error("Invalid credential host");
    return Credentials::normalize_host(value.get<std::string>());
}
bool valid_password(const std::string& value) {
    return !value.empty()&&value.size()<=1024&&std::none_of(value.begin(),value.end(),[](unsigned char c){return c==0||c==10||c==13;});
}
int nibble(char c){return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:-1;}
bool valid_blob(const std::string& value) {
    return !value.empty()&&value.size()<=max_blob_hex&&value.size()%2==0&&
        std::all_of(value.begin(),value.end(),[](char c){return nibble(c)>=0;});
}
std::string entropy(const std::string& host,int port){return "splay-credential-v1:"+host+":"+std::to_string(port);}
struct LocalBlob {
    DATA_BLOB value{};
    ~LocalBlob(){if(value.pbData){SecureZeroMemory(value.pbData,value.cbData);LocalFree(value.pbData);}}
};
std::string encrypt(const std::string& password,const std::string& host,int port) {
    auto additional=entropy(host,port);
    DATA_BLOB input{static_cast<DWORD>(password.size()),reinterpret_cast<BYTE*>(const_cast<char*>(password.data()))};
    DATA_BLOB extra{static_cast<DWORD>(additional.size()),reinterpret_cast<BYTE*>(additional.data())};
    LocalBlob output;
    // Deliberately omit CRYPTPROTECT_LOCAL_MACHINE: this is bound to the Windows user.
    if(!CryptProtectData(&input,nullptr,&extra,nullptr,nullptr,CRYPTPROTECT_UI_FORBIDDEN,&output.value))
        throw std::runtime_error("Windows could not encrypt the server password (error "+std::to_string(GetLastError())+"); password was not saved");
    static const char hex[]="0123456789abcdef";
    std::string result;result.reserve(output.value.cbData*2);
    for(DWORD i=0;i<output.value.cbData;++i){const auto b=output.value.pbData[i];result+=hex[b>>4];result+=hex[b&15];}
    return result;
}
std::string decrypt(const std::string& encrypted,const std::string& host,int port) {
    std::vector<BYTE> bytes(encrypted.size()/2);
    for(size_t i=0;i<bytes.size();++i)bytes[i]=static_cast<BYTE>((nibble(encrypted[i*2])<<4)|nibble(encrypted[i*2+1]));
    auto additional=entropy(host,port);
    DATA_BLOB input{static_cast<DWORD>(bytes.size()),bytes.data()};
    DATA_BLOB extra{static_cast<DWORD>(additional.size()),reinterpret_cast<BYTE*>(additional.data())};
    LocalBlob output;
    if(!CryptUnprotectData(&input,nullptr,&extra,nullptr,nullptr,CRYPTPROTECT_UI_FORBIDDEN,&output.value))
        throw std::runtime_error("Saved password cannot be decrypted by this Windows user; enter and save it again");
    if(output.value.cbData==0||output.value.cbData>1024)throw std::runtime_error("Saved password is invalid; enter and save it again");
    std::string result(reinterpret_cast<const char*>(output.value.pbData),output.value.cbData);
    if(!valid_password(result)){erase_secret(result);throw std::runtime_error("Saved password is invalid; enter and save it again");}
    return result;
}
Json read(const std::wstring& path) {
    const auto attributes=GetFileAttributesW(path.c_str());
    if(attributes==INVALID_FILE_ATTRIBUTES) {
        if(GetLastError()==ERROR_FILE_NOT_FOUND)return empty();
        throw std::runtime_error("Cannot read credential file");
    }
    std::ifstream file(std::filesystem::path(path),std::ios::binary|std::ios::ate);
    if(!file)throw std::runtime_error("Cannot read credential file");
    const auto size=file.tellg();
    if(size<0||size>static_cast<std::streamoff>(max_file))throw std::runtime_error("Credential file is too large; original file preserved");
    file.seekg(0);
    Json source;
    try {
        file>>source;file>>std::ws;
        if(!file.eof()||!source.is_object()||source.size()!=2||source.at("schema")!=1||!source.at("entries").is_array()||source["entries"].size()>max_entries)
            throw std::runtime_error("schema");
        Json seen=Json::array();
        for(const auto& item:source["entries"]) {
            if(!item.is_object()||item.size()!=3)throw std::runtime_error("entry");
            const auto host=host_text(item.at("host"));const auto port=port_number(item.at("port"));
            if(host!=item["host"]||!item.at("blob").is_string()||!valid_blob(item["blob"].get<std::string>()))throw std::runtime_error("entry");
            const Json key={host,port};
            if(std::find(seen.begin(),seen.end(),key)!=seen.end())throw std::runtime_error("duplicate");
            seen.push_back(key);
        }
    }catch(...) {throw std::runtime_error("Credential file is damaged or invalid; original file preserved");}
    return source;
}
void write(const std::wstring& path,const Json& value) {
    static std::atomic<unsigned> serial{0};
    const auto temp=path+L".tmp-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(++serial);
    try {
        const auto bytes=value.dump(2)+"\n";
        if(bytes.size()>max_file)throw std::runtime_error("Credential file is full; previous file preserved");
        {
            Handle file;
            file.value=CreateFileW(temp.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
            if(file.value==INVALID_HANDLE_VALUE)throw std::runtime_error("Cannot create credential temporary file; previous file preserved");
            DWORD written=0;
            if(!WriteFile(file.value,bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr)||written!=bytes.size()||!FlushFileBuffers(file.value))
                throw std::runtime_error("Cannot write credential file; previous file preserved");
        }
        const auto exists=GetFileAttributesW(path.c_str())!=INVALID_FILE_ATTRIBUTES;
        const bool ok=exists?ReplaceFileW(path.c_str(),temp.c_str(),nullptr,0,nullptr,nullptr)!=0:
            MoveFileExW(temp.c_str(),path.c_str(),MOVEFILE_WRITE_THROUGH)!=0;
        if(!ok)throw std::runtime_error("Cannot replace credential file; previous file preserved");
    }catch(...) {DeleteFileW(temp.c_str());throw;}
}
}
std::string Credentials::normalize_host(const std::string& host) {
    if(host.size()>1024)throw std::runtime_error("Invalid credential host");
    const auto first=host.find_first_not_of(" \t\r\n"),last=host.find_last_not_of(" \t\r\n");
    if(first==host.npos)throw std::runtime_error("Invalid credential host");
    auto result=host.substr(first,last-first+1);
    if(result.size()>253||std::any_of(result.begin(),result.end(),[](unsigned char c){return c<=32||c==127;}))
        throw std::runtime_error("Invalid credential host");
    for(auto& c:result)if(c>='A'&&c<='Z')c=static_cast<char>(c-'A'+'a');
    return result;
}
void erase_secret(std::string& value){if(!value.empty())SecureZeroMemory(value.data(),value.size());value.clear();}
Json Credentials::handle(const Json& command) {
    Json result={{"schema",1},{"saved",false}};
    try {
        if(!command.is_object()||!command.contains("action")||!command["action"].is_string())throw std::runtime_error("Invalid credential command");
        const auto action=command["action"].get<std::string>();
        if(action=="credential-init") {
            if(!command.contains("path")||!command["path"].is_string())throw std::runtime_error("Invalid credential path");
            // Set only after validation so a malformed reinitialization cannot change the active path.
            const auto candidate=command["path"].get<std::string>();const auto path=wide(candidate);
            Lock lock(path);read(path);path_=candidate;
            return result;
        }
        if(action!="credential-status"&&action!="credential-save"&&action!="credential-delete")throw std::runtime_error("Unknown credential command");
        if(!command.contains("host")||!command.contains("port"))throw std::runtime_error("Missing credential endpoint");
        const auto host=host_text(command["host"]);const auto port=port_number(command["port"]);
        result["host"]=host;result["port"]=port;
        std::string blob;
        if(action=="credential-save") {
            if(!command.contains("password")||!command["password"].is_string())throw std::runtime_error("Invalid server password");
            auto password=command["password"].get<std::string>();
            if(!valid_password(password)){erase_secret(password);throw std::runtime_error("Server password must contain 1 to 1024 bytes without line breaks");}
            try{blob=encrypt(password,host,port);}catch(...){erase_secret(password);throw;}
            erase_secret(password);
        }
        const auto path=wide(path_);Lock lock(path);auto value=read(path);
        auto& entries=value["entries"];
        auto found=std::find_if(entries.begin(),entries.end(),[&](const Json& entry){return entry["host"]==host&&entry["port"]==port;});
        result["saved"]=found!=entries.end();
        if(action=="credential-save") {
            if(found==entries.end()) {
                if(entries.size()>=max_entries)throw std::runtime_error("Too many saved server passwords; delete an unused entry first");
                entries.push_back({{"host",host},{"port",port},{"blob",blob}});
            }else (*found)["blob"]=blob;
            write(path,value);result["saved"]=true;
        }else if(action=="credential-delete") {
            if(found!=entries.end()){entries.erase(found);write(path,value);}
            result["saved"]=false;
        }
    }catch(const std::runtime_error& error){result["error"]=error.what();}
    catch(...){result["error"]="Invalid credential command or file; original file preserved";}
    return result;
}
std::string Credentials::password(const std::string& source_host,int port) const {
    const auto host=normalize_host(source_host);port_number(port);
    const auto path=wide(path_);Lock lock(path);const auto value=read(path);
    for(const auto& entry:value["entries"])if(entry["host"]==host&&entry["port"]==port)return decrypt(entry["blob"].get<std::string>(),host,port);
    throw std::runtime_error("No saved password for this server and port; enter the server password");
}
}
