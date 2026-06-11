import numpy as np
import time
import sys
from cyndilib.sender import Sender
from cyndilib.video_frame import VideoSendFrame
from cyndilib.wrapper.ndi_structs import FourCC

def main():
    print("Starting NDI Virtual Sender...")
    sender = Sender("Python Virtual Test Stream")
    
    # Configure NDI Video Frame properties
    vsf = VideoSendFrame()
    width = 1280
    height = 720
    fps = 30
    vsf.set_resolution(width, height)
    vsf.set_frame_rate(fps)
    vsf.set_fourcc(FourCC.RGBA)
    
    sender.set_video_frame(vsf)
    
    print("Opening NDI sender connection...")
    sender.open()
    print("----------------------------------------------------------------")
    print("NDI Source 'Python Virtual Test Stream' is now broadcasting.")
    print("Press Ctrl+C to stop broadcasting.")
    print("----------------------------------------------------------------")
    
    frame_interval = 1.0 / fps
    frame_count = 0
    
    try:
        # Precompute coordinate grids for performance
        x = np.linspace(0, 255, width, dtype=np.uint8)
        y = np.linspace(0, 255, height, dtype=np.uint8)
        xv, yv = np.meshgrid(x, y)
        
        while True:
            t0 = time.time()
            
            # Create dynamic gradient background
            img = np.zeros((height, width, 4), dtype=np.uint8)
            blue_val = int((time.time() * 20) % 255)
            img[..., 0] = xv                      # Red gradient (horizontal)
            img[..., 1] = yv                      # Green gradient (vertical)
            img[..., 2] = blue_val                # Blue (dynamic temporal cycle)
            img[..., 3] = 255                     # Alpha (Fully Opaque)
            
            # Calculate position for a bouncing box
            speed_x = 8
            speed_y = 5
            box_size = 120
            
            pos_x = int((frame_count * speed_x) % (width - box_size))
            pos_y = int((frame_count * speed_y) % (height - box_size))
            
            # Draw white box outer border
            img[pos_y:pos_y+box_size, pos_x:pos_x+box_size, 0:3] = 255
            # Draw red inner box
            img[pos_y+10:pos_y+box_size-10, pos_x+10:pos_x+box_size-10, 0] = 255
            img[pos_y+10:pos_y+box_size-10, pos_x+10:pos_x+box_size-10, 1] = 0
            img[pos_y+10:pos_y+box_size-10, pos_x+10:pos_x+box_size-10, 2] = 0
            
            # Write frame to NDI stream
            sender.write_video_async(img.ravel())
            
            frame_count += 1
            if frame_count % 150 == 0:
                print(f"Broadcast status: Sent {frame_count} frames successfully.")
            
            # Synchronize to match target FPS
            elapsed = time.time() - t0
            sleep_time = frame_interval - elapsed
            if sleep_time > 0:
                time.sleep(sleep_time)
                
    except KeyboardInterrupt:
        print("\nKeyboardInterrupt received. Stopping NDI stream...")
    finally:
        sender.close()
        print("NDI Sender closed.")

if __name__ == '__main__':
    main()
