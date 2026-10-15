#include "core/credentials.hpp"
#include <iostream>
#include <windows.h>
int wmain(int argc,wchar_t** argv) {
    if(argc!=2)return 2;
    const int size=WideCharToMultiByte(CP_UTF8,0,argv[1],-1,nullptr,0,nullptr,nullptr);
    std::string path(size,'\0');
    WideCharToMultiByte(CP_UTF8,0,argv[1],-1,path.data(),size,nullptr,nullptr);path.pop_back();
    splay::Credentials credentials;
    const auto initialized=credentials.handle({{"action","credential-init"},{"path",path}});
    std::string line;
    if(!std::getline(std::cin,line)){std::cout<<initialized.dump();return 0;}
    if(initialized.contains("error")){std::cout<<initialized.dump();return 0;}
    try {
        const auto command=nlohmann::json::parse(line);
        if(command.value("action","")=="test-compare") {
            auto password=credentials.password(command.at("host").get<std::string>(),command.at("port").get<int>());
            const bool matches=password==command.at("expected").get<std::string>();
            splay::erase_secret(password);
            std::cout<<nlohmann::json({{"matches",matches}}).dump();
        }else std::cout<<credentials.handle(command).dump();
    }catch(const std::runtime_error& error){std::cout<<nlohmann::json({{"error",error.what()}}).dump();}
    catch(...){std::cout<<"{\"error\":\"Invalid test input\"}";}
    return 0;
}
