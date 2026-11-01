import Foundation

/// All JS polyfills, injected via WKUserScript at document start (CSP-proof).
enum PolyfillJS {
    static let source = """
    (function(){'use strict';var patched=[];
    if(typeof AbortSignal!=='undefined'&&typeof AbortSignal.any!=='function'){
    Object.defineProperty(AbortSignal,'any',{configurable:true,writable:true,value:function(signals){
    var list=Array.from(signals);var controller=new AbortController();var i;
    for(i=0;i<list.length;i++){if(list[i].aborted){controller.abort(list[i].reason);return controller.signal;}}
    var onAbort=function(event){if(!controller.signal.aborted){controller.abort(event.target.reason);cleanup();}};
    var cleanup=function(){for(var j=0;j<list.length;j++){list[j].removeEventListener('abort',onAbort);}};
    for(i=0;i<list.length;i++){list[i].addEventListener('abort',onAbort,{once:true});}
    return controller.signal;}});patched.push('AbortSignal.any');}
    if(typeof AbortSignal!=='undefined'&&typeof AbortSignal.timeout!=='function'){
    Object.defineProperty(AbortSignal,'timeout',{configurable:true,writable:true,value:function(ms){
    var controller=new AbortController();
    setTimeout(function(){controller.abort(new DOMException('The operation timed out','TimeoutError'));},Math.max(0,Number(ms)||0));
    return controller.signal;}});patched.push('AbortSignal.timeout');}
    if(typeof Promise.withResolvers!=='function'){
    Object.defineProperty(Promise,'withResolvers',{configurable:true,writable:true,value:function(){
    var resolve,reject;var promise=new Promise(function(res,rej){resolve=res;reject=rej;});
    return{promise:promise,resolve:resolve,reject:reject};}});patched.push('Promise.withResolvers');}
    try{if(typeof window.OTPCredential==='undefined'){window.OTPCredential=function(){};patched.push('OTPCredential');}}catch(e){}
    try{
    if(typeof Array.prototype.toSorted!=='function'){
    Array.prototype.toSorted=function(c){return Array.prototype.slice.call(this).sort(c);};patched.push('Array.toSorted');}
    if(typeof Array.prototype.toReversed!=='function'){
    Array.prototype.toReversed=function(){return Array.prototype.slice.call(this).reverse();};patched.push('Array.toReversed');}
    if(typeof Array.prototype.toSpliced!=='function'){
    Array.prototype.toSpliced=function(s,dc){var a=Array.prototype.slice.call(this);var args=Array.prototype.slice.call(arguments,2);a.splice.apply(a,[s,dc].concat(args));return a;};patched.push('Array.toSpliced');}
    if(typeof Array.prototype.with!=='function'){
    Array.prototype.with=function(i,v){var a=Array.prototype.slice.call(this);a[i]=v;return a;};patched.push('Array.with');}
    if(typeof Array.prototype.findLast!=='function'){
    Array.prototype.findLast=function(fn){for(var i=this.length-1;i>=0;i--){if(fn(this[i],i,this))return this[i];}return undefined;};patched.push('Array.findLast');}
    if(typeof Array.prototype.findLastIndex!=='function'){
    Array.prototype.findLastIndex=function(fn){for(var i=this.length-1;i>=0;i--){if(fn(this[i],i,this))return i;}return -1;};patched.push('Array.findLastIndex');}
    }catch(e){}
    try{document.documentElement.setAttribute('data-muse-browser-polyfill',patched.join(','));}catch(e){}
    })();
    """
}
