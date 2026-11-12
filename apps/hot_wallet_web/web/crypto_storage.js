// Non-extractable Web Crypto API (SubtleCrypto AES-256-GCM) + IndexedDB persistence
window.CardanoWebCryptoStorage = (function () {
  const DB_NAME = 'cardano_hot_wallet_db';
  const DB_VERSION = 1;
  const KEY_STORE = 'keyStore';
  const DATA_STORE = 'dataStore';
  const MASTER_KEY_ID = 'hot_wallet_aes_gcm_v1';

  function openDb() {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, DB_VERSION);
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains(KEY_STORE)) {
          db.createObjectStore(KEY_STORE);
        }
        if (!db.objectStoreNames.contains(DATA_STORE)) {
          db.createObjectStore(DATA_STORE);
        }
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }

  async function getOrCreateKey(db) {
    const existing = await new Promise((resolve, reject) => {
      const tx = db.transaction(KEY_STORE, 'readonly');
      const req = tx.objectStore(KEY_STORE).get(MASTER_KEY_ID);
      req.onsuccess = () => resolve(req.result || null);
      req.onerror = () => reject(req.error);
    });
    if (existing) return existing;

    // Non-extractable CryptoKey: JS cannot export raw key material
    const newKey = await window.crypto.subtle.generateKey(
      { name: 'AES-GCM', length: 256 },
      false,
      ['encrypt', 'decrypt']
    );

    await new Promise((resolve, reject) => {
      const tx = db.transaction(KEY_STORE, 'readwrite');
      tx.objectStore(KEY_STORE).put(newKey, MASTER_KEY_ID);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
    return newKey;
  }

  return {
    isSupported: function () {
      return Boolean(window.crypto && window.crypto.subtle && window.indexedDB);
    },

    saveEncrypted: async function (key, plaintext) {
      const db = await openDb();
      const cryptoKey = await getOrCreateKey(db);
      const iv = window.crypto.getRandomValues(new Uint8Array(12));
      const encoded = new TextEncoder().encode(plaintext);
      const ciphertext = await window.crypto.subtle.encrypt(
        { name: 'AES-GCM', iv: iv },
        cryptoKey,
        encoded
      );
      await new Promise((resolve, reject) => {
        const tx = db.transaction(DATA_STORE, 'readwrite');
        tx.objectStore(DATA_STORE).put({ iv: iv, ciphertext: ciphertext }, key);
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
      });
      return true;
    },

    loadEncrypted: async function (key) {
      const db = await openDb();
      const record = await new Promise((resolve, reject) => {
        const tx = db.transaction(DATA_STORE, 'readonly');
        const req = tx.objectStore(DATA_STORE).get(key);
        req.onsuccess = () => resolve(req.result || null);
        req.onerror = () => reject(req.error);
      });
      if (!record) return null;
      const cryptoKey = await getOrCreateKey(db);
      const plaintextBuf = await window.crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: record.iv },
        cryptoKey,
        record.ciphertext
      );
      return new TextDecoder().decode(plaintextBuf);
    },

    deleteEncrypted: async function (key) {
      const db = await openDb();
      await new Promise((resolve, reject) => {
        const tx = db.transaction(DATA_STORE, 'readwrite');
        tx.objectStore(DATA_STORE).delete(key);
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
      });
      return true;
    }
  };
})();
