// Web Webcam & Image QR Scanner bridge (BarcodeDetector + self-hosted jsQR fallback)
window.CardanoWebQrScanner = (function () {
  function decodeImageData(imageData) {
    if (typeof window.jsQR === 'function') {
      const code = window.jsQR(imageData.data, imageData.width, imageData.height, {
        inversionAttempts: 'attemptBoth',
      });
      if (code && code.data) {
        return code.data;
      }
    }
    return null;
  }

  return {
    startCameraScanner: async function (containerEl, onQrFound, onError) {
      let stream = null;
      let stopped = false;
      let rafId = null;

      try {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
          throw new Error('getUserMedia is not supported (requires HTTPS or localhost)');
        }
        stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 } },
          audio: false,
        });
      } catch (err) {
        onError(err && err.message ? err.message : String(err));
        return { stop: function () {} };
      }

      const video = document.createElement('video');
      video.setAttribute('playsinline', 'true');
      video.muted = true;
      video.autoplay = true;
      video.srcObject = stream;
      video.style.width = '100%';
      video.style.height = '100%';
      video.style.objectFit = 'cover';
      containerEl.innerHTML = '';
      containerEl.appendChild(video);

      const canvas = document.createElement('canvas');
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      const detector = ('BarcodeDetector' in window)
        ? new window.BarcodeDetector({ formats: ['qr_code'] })
        : null;

      let scanning = false;

      async function tick() {
        if (stopped) return;
        if (!scanning && video.readyState >= 2 && video.videoWidth > 0) {
          scanning = true;
          try {
            if (detector) {
              const results = await detector.detect(video);
              if (results && results.length > 0 && results[0].rawValue) {
                onQrFound(results[0].rawValue);
              }
            } else {
              canvas.width = video.videoWidth;
              canvas.height = video.videoHeight;
              ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
              const imgData = ctx.getImageData(0, 0, canvas.width, canvas.height);
              const decoded = decodeImageData(imgData);
              if (decoded) {
                onQrFound(decoded);
              }
            }
          } catch (_) {
            // Fallback to jsQR if BarcodeDetector throws
            try {
              canvas.width = video.videoWidth;
              canvas.height = video.videoHeight;
              ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
              const imgData = ctx.getImageData(0, 0, canvas.width, canvas.height);
              const decoded = decodeImageData(imgData);
              if (decoded) {
                onQrFound(decoded);
              }
            } catch (_) {}
          } finally {
            scanning = false;
          }
        }
        rafId = requestAnimationFrame(tick);
      }

      video.play().then(() => {
        rafId = requestAnimationFrame(tick);
      }).catch((err) => {
        onError(err && err.message ? err.message : String(err));
      });

      return {
        stop: function () {
          stopped = true;
          if (rafId !== null) cancelAnimationFrame(rafId);
          if (stream) {
            stream.getTracks().forEach((t) => t.stop());
          }
        },
      };
    },
  };
})();
