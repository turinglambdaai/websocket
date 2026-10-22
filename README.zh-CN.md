# websocket

[English](README.md) · **中文**

[![CI](https://github.com/turinglambdaai/websocket/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/websocket/actions/workflows/ci.yml)

Racket 的 RFC 6455 WebSocket 客户端与服务端实现。这是协议库而不是框架：连接被抽象成 Racket port 风格的对象，路由、会话、序列化一切都留给调用者。

## 安装

```
raco pkg install websocket
```

## 使用

客户端：

```racket
(require websocket)
(define conn (ws-connect "ws://localhost:8080/chat"))
(ws-send-text! conn "hello")
(define msg (ws-recv conn))          ; (ws-message 'text #"hello back")
(ws-close! conn)
```

服务端：

```racket
(require websocket racket/tcp)
(define listener (tcp-listen 8080 16 #t "127.0.0.1"))
(ws-serve listener
          (λ (conn)
            (let loop ()
              (define m (ws-recv conn))
              (unless (eof-object? m)
                (ws-send-text! conn "welcome")
                (loop)))))
```

你能得到什么：

- 符合 RFC 6455：opening handshake、帧编解码、掩码、分片、控制帧、关闭握手、UTF-8 校验
- `ws://` 与 `wss://` 客户端 URL（纯 TCP 与 TLS）
- 发送线程安全：一个线程停在 `ws-recv` 时另一个线程可以发送
- 接收途中透明处理 ping/pong；协议违规会用正确的状态码关连接（1002/1007）
- 原始帧编解码层对外暴露，可用于代理与测试

已知限制：不支持 permessage-deflate；无后台保活线程。

## 开发

```
raco pkg install --auto --link .
raco test tests
raco setup --check-pkg-deps -l websocket
```

## 许可证

[MIT](LICENSE)
