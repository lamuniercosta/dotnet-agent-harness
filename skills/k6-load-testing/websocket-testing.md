# WebSocket Testing

## WebSocket Testing

```javascript
import ws from 'k6/ws';
import { check } from 'k6';

export default function () {
  const url = 'wss://echo.websocket.org';
  
  ws.connect(url, {}, function (socket) {
    socket.on('open', () => {
      console.log('WebSocket connected');
      socket.send('Hello WebSocket');
    });
    
    socket.on('message', (data) => {
      console.log(`Received: ${data}`);
      check(data, {
        'echo received': (d) => d.includes('Hello'),
      });
    });
    
    socket.on('close', () => {
      console.log('WebSocket closed');
    });
    
    // Send periodic messages
    socket.setInterval(function () {
      socket.send('ping');
    }, 1000);
    
    // Close after 5 seconds
    socket.setTimeout(function () {
      socket.close();
    }, 5000);
  });
}
```

---
