#!/usr/bin/env python3
"""
Professional Remote Mouse Server
Production-ready server for remote mouse control via WebSocket
Supports device discovery, secure PIN authentication, and robust error handling
"""

import asyncio
import json
import socket
import threading
import time
import logging
from typing import Optional, Dict, Any
import websockets
from pynput.mouse import Controller as Mouse, Button
from pynput.keyboard import Controller as Keyboard, Key

# Configuration
CONFIG = {
    "pin": "123456",
    "ws_port": 8765,
    "discovery_port": 9876,
    "server_name": "RemoteMouse Pro",
    "max_connections": 10,
    "ping_timeout": 30,
    "ping_interval": 10,
    "discovery_timeout": 0.5,  # Response timeout for discovery
}

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class RemoteMouseServer:
    def __init__(self):
        self.mouse = Mouse()
        self.keyboard = Keyboard()
        self.active_connections = set()
        self.server_running = False
        self.local_ip = self.get_local_ip()
        
        # Detect operating system for proper key mappings
        import platform
        self.os_type = platform.system().lower()
        
        # Key mappings for hotkeys with OS-specific modifiers
        self.key_mapping = {
            "ctrl": Key.ctrl, "shift": Key.shift, "alt": Key.alt, 
            "cmd": Key.cmd if self.os_type == "darwin" else Key.ctrl,  # macOS uses cmd, others use ctrl
            "win": Key.cmd,  # Windows key
            "enter": Key.enter, "tab": Key.tab, "esc": Key.esc, "space": Key.space,
            "up": Key.up, "down": Key.down, "left": Key.left, "right": Key.right,
            "backspace": Key.backspace, "delete": Key.delete, "home": Key.home, 
            "end": Key.end, "pageup": Key.page_up, "pagedown": Key.page_down,
            "f1": Key.f1, "f2": Key.f2, "f3": Key.f3, "f4": Key.f4, "f5": Key.f5,
            "f6": Key.f6, "f7": Key.f7, "f8": Key.f8, "f9": Key.f9, "f10": Key.f10,
            "f11": Key.f11, "f12": Key.f12
        }

    def get_local_ip(self) -> str:
        """Get the local IP address safely"""
        try:
            # Try multiple methods to get local IP
            methods = [
                ("8.8.8.8", 80),
                ("1.1.1.1", 80),
                ("google.com", 80)
            ]
            
            for host, port in methods:
                try:
                    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    s.settimeout(2)
                    s.connect((host, port))
                    ip = s.getsockname()[0]
                    s.close()
                    if ip and ip != "127.0.0.1":
                        return ip
                except:
                    continue
                    
            # Fallback: get hostname IP
            hostname = socket.gethostname()
            return socket.gethostbyname(hostname)
        except Exception as e:
            logger.warning(f"Could not determine local IP: {e}")
            return "127.0.0.1"

    def discovery_server(self):
        """UDP discovery server with improved error handling"""
        logger.info(f"Starting discovery server on port {CONFIG['discovery_port']}")
        
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.settimeout(1.0)  # Non-blocking with timeout
            sock.bind(("", CONFIG['discovery_port']))
            
            while self.server_running:
                try:
                    data, addr = sock.recvfrom(1024)
                    message = data.decode('utf-8', errors='ignore').strip()
                    
                    if message == "remotemouse:discover":
                        logger.info(f"Discovery request from {addr[0]}")
                        
                        # Create response payload
                        response = {
                            "name": CONFIG["server_name"],
                            "ip": self.local_ip,
                            "port": CONFIG["ws_port"],
                            "pin_required": True,
                            "version": "2.0",
                            "capabilities": ["mouse", "keyboard", "hotkeys", "scroll"]
                        }
                        
                        # Send response with timeout
                        try:
                            sock.settimeout(CONFIG['discovery_timeout'])
                            sock.sendto(json.dumps(response).encode('utf-8'), addr)
                            logger.info(f"Sent discovery response to {addr[0]}")
                        except Exception as e:
                            logger.error(f"Failed to send discovery response: {e}")
                            
                except socket.timeout:
                    continue
                except Exception as e:
                    logger.error(f"Discovery server error: {e}")
                    time.sleep(0.1)
                    
        except Exception as e:
            logger.error(f"Failed to start discovery server: {e}")
        finally:
            try:
                sock.close()
            except:
                pass

    def press_hotkey(self, keys: list):
        """Execute hotkey combination with error handling and OS-specific mapping"""
        try:
            if not keys:
                return
            
            # Convert and normalize keys for the current OS
            normalized_keys = self.normalize_hotkey_for_os(keys)
            
            # Convert string keys to Key objects
            key_sequence = []
            for key in normalized_keys:
                if isinstance(key, str):
                    mapped_key = self.key_mapping.get(key.lower(), key)
                    key_sequence.append(mapped_key)
                else:
                    key_sequence.append(key)
            
            # Press all keys
            for key in key_sequence:
                self.keyboard.press(key)
            
            # Small delay to ensure proper key registration
            import time
            time.sleep(0.01)
            
            # Release in reverse order
            for key in reversed(key_sequence):
                self.keyboard.release(key)
                
            logger.debug(f"Executed hotkey: {keys} -> {normalized_keys}")
        except Exception as e:
            logger.error(f"Hotkey error: {e}")

    def normalize_hotkey_for_os(self, keys: list) -> list:
        """Normalize hotkey combinations for the current operating system"""
        normalized = []
        
        for key in keys:
            key_lower = key.lower()
            
            # Handle OS-specific modifier key mappings
            if self.os_type == "darwin":  # macOS
                if key_lower == "ctrl":
                    normalized.append("cmd")  # Use Cmd instead of Ctrl on macOS
                elif key_lower == "cmd":
                    normalized.append("cmd")
                elif key_lower == "alt":
                    normalized.append("alt")  # Option key on macOS
                else:
                    normalized.append(key_lower)
            else:  # Windows/Linux
                if key_lower == "cmd":
                    normalized.append("ctrl")  # Use Ctrl instead of Cmd on Windows/Linux
                elif key_lower == "ctrl":
                    normalized.append("ctrl")
                elif key_lower == "alt":
                    normalized.append("alt")
                else:
                    normalized.append(key_lower)
        
        return normalized

    async def handle_client(self, websocket):
        """Handle WebSocket client connection"""
        client_ip = websocket.remote_address[0]
        logger.info(f"New connection from {client_ip}")
        
        try:
            # Authentication handshake
            if not await self.authenticate_client(websocket):
                return
                
            self.active_connections.add(websocket)
            logger.info(f"Client {client_ip} authenticated successfully")
            
            # Send success response
            await websocket.send(json.dumps({
                "t": "ok", 
                "server": CONFIG["server_name"],
                "capabilities": ["mouse", "keyboard", "hotkeys", "scroll"]
            }))
            
            # Handle messages
            async for raw_message in websocket:
                try:
                    await self.process_message(websocket, raw_message)
                except Exception as e:
                    logger.error(f"Message processing error: {e}")
                    await websocket.send(json.dumps({
                        "t": "error", 
                        "msg": "Invalid message format"
                    }))
                    
        except websockets.exceptions.ConnectionClosed:
            logger.info(f"Client {client_ip} disconnected")
        except Exception as e:
            logger.error(f"Client handler error: {e}")
        finally:
            self.active_connections.discard(websocket)

    async def authenticate_client(self, websocket) -> bool:
        """Authenticate client with PIN"""
        try:
            # Wait for hello message with timeout
            hello_message = await asyncio.wait_for(websocket.recv(), timeout=5)
            logger.info(f"Received authentication message: {hello_message}")
            
            hello_data = json.loads(hello_message)
            
            if hello_data.get("t") != "hello":
                logger.warning(f"Invalid message type: {hello_data.get('t')}")
                await websocket.send(json.dumps({
                    "t": "error", 
                    "msg": "Invalid message type, expected 'hello'"
                }))
                await websocket.close()
                return False
                
            if hello_data.get("pin") != CONFIG["pin"]:
                logger.warning(f"Invalid PIN: {hello_data.get('pin')}")
                await websocket.send(json.dumps({
                    "t": "error", 
                    "msg": "Invalid PIN"
                }))
                await websocket.close()
                return False
                
            return True
        except asyncio.TimeoutError:
            logger.warning("Authentication timeout - no hello message received")
            await websocket.send(json.dumps({
                "t": "error", 
                "msg": "Authentication timeout"
            }))
            await websocket.close()
            return False
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in hello message: {e}")
            await websocket.send(json.dumps({
                "t": "error", 
                "msg": "Invalid JSON format"
            }))
            await websocket.close()
            return False
        except Exception as e:
            logger.error(f"Authentication error: {e}")
            await websocket.close()
            return False

    async def process_message(self, websocket, raw_message: str):
        """Process incoming WebSocket message"""
        try:
            message = json.loads(raw_message)
            message_type = message.get("t")
            
            if message_type == "move":
                dx = float(message.get("dx", 0))
                dy = float(message.get("dy", 0))
                # Scale movement for better control
                self.mouse.move(dx * 1.5, dy * 1.5)
                
            elif message_type == "click":
                btn = message.get("btn", "left")
                button_map = {
                    "left": Button.left,
                    "right": Button.right, 
                    "middle": Button.middle
                }
                button = button_map.get(btn, Button.left)
                
                if message.get("down") is True:
                    self.mouse.press(button)
                elif message.get("down") is False:
                    self.mouse.release(button)
                else:
                    self.mouse.click(button, 1)
                    
            elif message_type == "scroll":
                dx = int(message.get("dx", 0))
                dy = int(message.get("dy", 0))
                self.mouse.scroll(dx, dy)
                
            elif message_type == "key":
                text = message.get("text", "")
                if text:
                    self.keyboard.type(text)
                    
            elif message_type == "hotkey":
                keys = message.get("keys", [])
                self.press_hotkey(keys)
                
            elif message_type == "ping":
                await websocket.send(json.dumps({"t": "pong"}))
                
            else:
                logger.warning(f"Unknown message type: {message_type}")
                
        except Exception as e:
            logger.error(f"Message processing error: {e}")
            raise

    async def start_websocket_server(self):
        """Start the WebSocket server"""
        logger.info(f"Starting WebSocket server on {self.local_ip}:{CONFIG['ws_port']}")
        
        # Create a wrapper function that handles both old and new websockets API
        async def handler(websocket, path=None):
            await self.handle_client(websocket)
        
        server = await websockets.serve(
            handler,
            "0.0.0.0",
            CONFIG['ws_port'],
            ping_timeout=CONFIG['ping_timeout'],
            ping_interval=CONFIG['ping_interval'],
            max_size=1024*1024,  # 1MB max message size
            compression=None,  # Disable compression for better performance
        )
        
        logger.info(f"✅ Server ready!")
        logger.info(f"📱 Connect your device to: ws://{self.local_ip}:{CONFIG['ws_port']}")
        logger.info(f"🔐 PIN: {CONFIG['pin']}")
        logger.info(f"🔍 Discovery running on UDP port {CONFIG['discovery_port']}")
        
        return server

    async def run(self):
        """Main server run method"""
        self.server_running = True
        
        # Start discovery server in background thread
        discovery_thread = threading.Thread(target=self.discovery_server, daemon=True)
        discovery_thread.start()
        
        try:
            # Start WebSocket server
            server = await self.start_websocket_server()
            
            # Keep server running
            await server.wait_closed()
            
        except KeyboardInterrupt:
            logger.info("Shutdown requested")
        except Exception as e:
            logger.error(f"Server error: {e}")
        finally:
            self.server_running = False

def main():
    """Entry point"""
    print("🖱️  Professional Remote Mouse Server")
    print("=" * 40)
    
    try:
        server = RemoteMouseServer()
        asyncio.run(server.run())
    except KeyboardInterrupt:
        print("\n👋 Server stopped")
    except Exception as e:
        logger.error(f"Fatal error: {e}")

if __name__ == "__main__":
    main()