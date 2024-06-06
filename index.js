const screenshot = require('screenshot-desktop');
const Jimp = require('jimp');
const fs = require('fs');

async function captureAndResize() {
    try {
        // Capture the screen to a buffer
        const imgBuffer = await screenshot();

        // Load the image buffer into Jimp
        const image = await Jimp.read(imgBuffer);

        // Resize the image to 480 pixels wide, maintaining aspect ratio
        image.resize(480, Jimp.AUTO);

        // Save the image
        const timestamp = Date.now();
        image.quality(60); // Set quality to 60 (adjustable)
        await image.writeAsync(`screenshot_${timestamp}.jpg`);
        console.log(`Saved screenshot_${timestamp}.jpg`);

        // Set to take another screenshot in 10 second
        setTimeout(captureAndResize, 10000);
    } catch (error) {
        console.error('Failed to capture and resize screenshot:', error);
    }
}

captureAndResize();  // Start the process
