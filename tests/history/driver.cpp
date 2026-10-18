#include "core/history.hpp"
#include <iostream>
#include <windows.h>
int wmain(int argc,wchar_t** argv) {
    if(argc!=2&&argc!=3)return 2;
    splay::History history;
    const int size=WideCharToMultiByte(CP_UTF8,0,argv[1],-1,nullptr,0,nullptr,nullptr);
    std::string path(size,'\0');
    WideCharToMultiByte(CP_UTF8,0,argv[1],-1,path.data(),size,nullptr,nullptr);path.pop_back();
    const auto loaded=history.handle({{"action","history-load"},{"path",path}});
    if(argc==3) {
        std::cout<<loaded.dump()<<std::endl;
        std::string command;
        while(std::getline(std::cin,command)) {
            try {std::cout<<history.handle(splay::Json::parse(command)).dump()<<std::endl;}
            catch(const std::exception& error){std::cout<<splay::Json({{"error",error.what()}}).dump()<<std::endl;}
        }
        return 0;
    }
    std::string line;
    if(!std::getline(std::cin,line)){std::cout<<loaded.dump();return 0;}
    try {std::cout<<history.handle(splay::Json::parse(line)).dump();}
    catch(const std::exception& error){std::cout<<splay::Json({{"error",error.what()}}).dump();}
    return 0;
}
