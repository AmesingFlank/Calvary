#include "Lexing.h"
#include <cctype> 
#include "../Utils/GpuCommons.h"
#include "../Utils/Utils.h"



TokenBuf runLexing(const std::filesystem::path& inputPath){
    std::string input = readTextFile(inputPath.string());
    TokenBuf result;
    int pos = 0;
    while(pos < input.size()){
        if(input[pos] == ' ' || input[pos] == '\n' || input[pos] == '\t'){
            ++pos;
            continue;
        }
        else if(input[pos]=='#'){
            while(pos<input.size() && input[pos] != '\n'){
                ++pos;
            }
            ++pos;
            continue;
        }
        else if(input[pos]=='['){
            result.tokens.push_back(LeftSquareBracketToken());
            ++pos;
            continue;
        }
        else if(input[pos]==']'){
            result.tokens.push_back(RightSquareBracketToken());
            ++pos;
            continue;
        }
        

        else if(isLetter(input[pos])){
            KeyWordToken::read(input,pos,result);
            continue;
        }
        else if(input[pos]=='\"'){
            StringToken::read(input,pos,result);
            continue;
        }
        else if(isDigit(input[pos]) || input[pos] == '-' ||input[pos] == '.' ){
            NumToken::read(input,pos,result);
        }
        else {
            SIGNAL_ERROR("unrecognized character %c\n", input[pos]);
        }
    }
    return result;
}

#define SIGNAL_LEXING_ERROR(err,pos) SIGNAL_ERROR((std::string("Lexing Error: ")+err+std::string("\n at")+std::to_string(pos)).c_str())


void KeyWordToken::read(const std::string& input, int& pos, TokenBuf& result){
    std::string word;
    for(;pos<input.size();++pos){
        if(isLetter(input[pos])){
            word += input[pos];
        }
        else{
            break;
        }
    }
    result.tokens.push_back(KeyWordToken(word));
}


void StringToken::read(const std::string& input, int& pos, TokenBuf& result){
    std::string raw;
    if(input[pos]!='\"'){
        SIGNAL_LEXING_ERROR("StringToken should begin with quotation.",pos);
    }
    ++pos;
    for(;pos < input.size() && input[pos]!='\"';++pos){
        raw += input[pos];
    }
    if(pos==input.size()){
        SIGNAL_LEXING_ERROR("Didn't find ending quotation",pos);
    }
    ++pos;
    result.tokens.push_back(StringToken(raw));
}


void NumToken::read(const std::string& input, int& pos, TokenBuf& result){
    std::string raw;
    for(;pos<input.size();++pos){
        if(isDigit(input[pos]) || input[pos]=='-' || input[pos] == '.' || input[pos]=='e'){
            raw += input[pos];
        }
        else{
            break;
        }
    }
    if(raw[0]=='.'){
        raw = std::string("0")+raw;
    }
    result.tokens.push_back(NumToken(std::stof(raw)));
}



const std::unordered_set<std::string> KeyWordToken::recognized =
{"ReverseOrientation","Material","MakeNamedMedium","MediumInterface","NamedMedium","Include","PixelFilter","Transform", "NamedMaterial","TransformBegin","TransformEnd","AreaLightSource","MakeNamedMaterial", "Texture","Scale","Rotate","Translate","LightSource","LookAt","Camera","Film","WorldBegin","WorldEnd","AttributeBegin","AttributeEnd","Sampler","Material","Shape","Integrator" };
