import 'dart:async';
import 'dart:io';

String userFacingError(Object error) {
  if (error is TimeoutException) {
    final String detail = error.message?.trim() ?? 'Future not completed';
    return '操作超时：接收端未在限定时间内响应，请等待重连后重试（$detail）';
  }
  if (error is SocketException) {
    return '网络连接已中断，请等待重连后重试（${error.message}）';
  }
  if (error is TlsException) return error.message;
  return error.toString().replaceFirst(
    RegExp(r'^(Bad state|Exception|FormatException):\s*'),
    '',
  );
}
