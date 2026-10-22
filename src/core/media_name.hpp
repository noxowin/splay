#pragma once
#include <cctype>
#include <string>
#include <utility>

namespace splay {
    inline std::string media_name_lower(std::string value){
        for(auto& ch:value)if(static_cast<unsigned char>(ch)<128)ch=static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
        return value;
    }
    inline std::string media_name_unescape(const std::string& value){
        auto hex=[](unsigned char ch)->int{
            if(ch>='0'&&ch<='9')return ch-'0';
            if(ch>='a'&&ch<='f')return ch-'a'+10;
            if(ch>='A'&&ch<='F')return ch-'A'+10;
            return -1;
        };
        std::string result;
        for(size_t n=0;n<value.size();++n){
            if(value[n]=='%'&&n+2<value.size()){
                const int high=hex(value[n+1]),low=hex(value[n+2]);
                if(high>=0&&low>=0){result+=static_cast<char>((high<<4)|low);n+=2;continue;}
            }
            result+=value[n];
        }
        return result;
    }
    inline bool network_media_path(const std::string& path){
        if(path.empty()||!std::isalpha(static_cast<unsigned char>(path[0])))return false;
        if(path.size()>2&&path[1]==':'&&(path[2]=='/'||path[2]=='\\'))return false;
        if(media_name_lower(path.substr(0,7))=="file://")return false;
        for(size_t n=1;n<path.size();++n){
            const auto ch=static_cast<unsigned char>(path[n]);
            if(ch==':')return true;
            if(!std::isalnum(ch)&&ch!='+'&&ch!='-'&&ch!='.')break;
        }
        return false;
    }
    // A public name is plain text, never an address, path or request data.
    // Inspect percent escapes too, but retain the original human-readable text.
    inline std::string public_media_name(std::string value){
        if(value.empty()||value.size()>8192)return {};
        auto inspected=value;
        for(int n=0;n<2;++n)inspected=media_name_unescape(inspected);
        inspected=media_name_lower(std::move(inspected));
        if(inspected.find_first_of("/\\?#=")!=inspected.npos||inspected.find("://")!=inspected.npos||
           inspected.find("www.")!=inspected.npos)return {};
        for(unsigned char ch:inspected)if(ch<32||ch==127)return {};
        for(const char* prefix:{"http:","https:","ftp:","ftps:","rtsp:","rtmp:","data:","file:","magnet:"})
            if(inspected.find(prefix)!=inspected.npos)return {};
        if(inspected.size()>=2&&std::isalpha(static_cast<unsigned char>(inspected[0]))&&inspected[1]==':')return {};
        const auto first=value.find_first_not_of(' ');
        if(first==value.npos)return {};
        value=value.substr(first,value.find_last_not_of(' ')-first+1);
        // Validate UTF-8 and cap at complete code points so JSON emission cannot
        // fail or publish a partial character from an external player property.
        size_t count=0,end=0;
        for(size_t pos=0;pos<value.size();){
            const auto ch=static_cast<unsigned char>(value[pos]);
            size_t length=ch<0x80?1:ch>=0xc2&&ch<=0xdf?2:ch>=0xe0&&ch<=0xef?3:ch>=0xf0&&ch<=0xf4?4:0;
            if(!length||pos+length>value.size())return {};
            for(size_t n=1;n<length;++n)if((static_cast<unsigned char>(value[pos+n])&0xc0)!=0x80)return {};
            if(length>=3){
                const auto next=static_cast<unsigned char>(value[pos+1]);
                if((ch==0xe0&&next<0xa0)||(ch==0xed&&next>=0xa0)||(ch==0xf0&&next<0x90)||(ch==0xf4&&next>=0x90))return {};
            }
            pos+=length;
            if(++count<=250)end=pos;
        }
        return value.substr(0,end);
    }
    inline std::string local_media_name(std::string path){
        if(network_media_path(path))return {};
        auto inspected=media_name_lower(media_name_unescape(media_name_unescape(path)));
        if(inspected.find("://")!=inspected.npos&&inspected.rfind("file://",0)!=0)return {};
        if(media_name_lower(path.substr(0,7))=="file://"){
            path=path.substr(7);
            path=path.substr(0,path.find_first_of("?#"));
            const auto slash=path.find_last_of("/\\");
            path=media_name_unescape(slash==path.npos?path:path.substr(slash+1));
        }
        else{
            const auto slash=path.find_last_of("/\\");
            if(slash!=path.npos)path=path.substr(slash+1);
        }
        return public_media_name(std::move(path));
    }
    inline std::string peer_media_name(const std::string& value){
        auto name=public_media_name(value);
        return name.empty()?local_media_name(value):name;
    }
    inline std::string network_media_name(const std::string& title,const std::string& filename,const std::string& filename_stem,bool explicit_title=false){
        auto name=public_media_name(title);
        if(name.empty())return {};
        const auto lower=media_name_lower(name);
        auto filename_fallback=[&](std::string value){
            value=media_name_lower(media_name_unescape(media_name_unescape(value)));
            value=value.substr(0,value.find_first_of("?#"));
            return lower==value||lower==media_name_lower(public_media_name(std::move(value)));
        };
        if(!explicit_title&&(filename_fallback(filename)||filename_fallback(filename_stem)))return {};
        const auto dot=lower.find_last_of('.');
        const auto stem=lower.substr(0,dot);
        for(const char* generic:{"index","master","manifest","playlist","token","stream","live","media","video","play"})
            if(stem==generic)return {};
        if(dot!=lower.npos){
            const auto extension=lower.substr(dot);
            for(const char* manifest:{".m3u8",".mpd",".ism",".isml",".f4m"})if(extension==manifest)return {};
        }
        return name;
    }
}
