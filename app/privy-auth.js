import React, { useEffect } from 'https://esm.sh/react@18.3.1';
import { createRoot } from 'https://esm.sh/react-dom@18.3.1/client?external=react';
import { PrivyProvider, usePrivy, useWallets, useCreateWallet } from 'https://esm.sh/@privy-io/react-auth@3.51.3?external=react,react-dom';

const APP_ID = 'cmwczpwcr001a0gkzk472t8s4';
const API_BASE = 'https://hormus-backend-production.up.railway.app';

// Robinhood Chain. RPC goes through the HORMUS backend relay because some ISPs block the public RPC domain.
const robinhoodChain = {
  id: 4663,
  name: 'Robinhood Chain',
  network: 'robinhood',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [`${API_BASE}/rpc`] }, public: { http: [`${API_BASE}/rpc`] } },
  blockExplorers: { default: { name: 'Blockscout', url: 'https://robinhoodchain.blockscout.com' } }
};

function publishWallets(ready, wallets) {
  // Embedded (Privy) wallet first, then any linked external wallet.
  const list = [...wallets].sort((a, b) => (a.walletClientType === 'privy' ? -1 : 0) - (b.walletClientType === 'privy' ? -1 : 0));
  window.__hormusWallets = {
    ready,
    list: list.map((w) => ({
      address: w.address,
      type: w.walletClientType === 'privy' ? 'embedded' : 'external',
      label: w.walletClientType === 'privy' ? 'HORMUS wallet (Privy)' : (w.walletClientType || 'External wallet'),
      async provider() { try { await w.switchChain(robinhoodChain.id); } catch (e) { console.warn('Chain switch failed', e); } return w.getEthereumProvider(); }
    }))
  };
  window.dispatchEvent(new CustomEvent('hormus:wallets', { detail: { ready, count: list.length } }));
}

function AuthBridge() {
  const { ready, authenticated, user, login, logout, getAccessToken } = usePrivy();
  const { wallets, ready: walletsReady } = useWallets();
  const { createWallet } = useCreateWallet();

  useEffect(() => {
    window.__hormusPrivy = { ready, authenticated, user, login, logout, getAccessToken, createWallet };
    window.__privyBridgeLoaded = true;
    if (!ready) return;
    window.__privyReady = true;
    window.__privyAuthenticated = authenticated;
    window.dispatchEvent(new CustomEvent('hormus:auth-state', { detail: { ready, authenticated, user } }));
    if (typeof window.route === 'function') window.route();
  }, [ready, authenticated, user, login, logout, getAccessToken, createWallet]);

  useEffect(() => { publishWallets(walletsReady && authenticated, authenticated ? wallets : []); }, [wallets, walletsReady, authenticated]);

  // createOnLogin only runs during a fresh login. Users who were already signed in before it was
  // switched on (or whose creation failed) get their embedded wallet here, once per page load.
  useEffect(() => {
    if (!ready || !authenticated || !walletsReady || window.__hormusWalletCreateTried) return;
    const hasEmbedded = wallets.some((w) => w.walletClientType === 'privy')
      || (user?.linkedAccounts || []).some((a) => a.type === 'wallet' && a.walletClientType === 'privy');
    if (hasEmbedded) return;
    window.__hormusWalletCreateTried = true;
    createWallet().catch((error) => console.warn('HORMUS wallet creation skipped:', error?.message || error));
  }, [ready, authenticated, walletsReady, wallets, user, createWallet]);

  useEffect(() => {
    const onLogin = async () => {
      try { await login(); }
      catch (error) {
        console.error('HORMUS Google sign-in failed', error);
        window.dispatchEvent(new CustomEvent('hormus:auth-error', { detail: { message: error?.message || 'Unable to start Google sign-in.' } }));
      }
    };
    const onLogout = async () => {
      try {
        await logout();
        window.__privyAuthenticated = false;
        history.replaceState({}, '', location.hostname === 'app.hormus.io' ? '/login' : '/');
        if (typeof window.route === 'function') window.route();
      } catch (error) {
        console.error('HORMUS logout failed', error);
      }
    };
    window.addEventListener('hormus:login', onLogin);
    window.addEventListener('hormus:logout', onLogout);
    return () => {
      window.removeEventListener('hormus:login', onLogin);
      window.removeEventListener('hormus:logout', onLogout);
    };
  }, [login, logout]);

  return null;
}

function Root() {
  return React.createElement(PrivyProvider, {
    appId: APP_ID,
    config: {
      loginMethods: ['google'],
      appearance: {
        theme: 'dark',
        accentColor: '#77e7c5',
        logo: 'https://hormus.io/apple-touch-icon.png',
        showWalletLoginFirst: false,
        walletChainType: 'ethereum-only'
      },
      // Every user gets a self-custodial Privy wallet on Robinhood Chain the first time they sign in.
      embeddedWallets: { ethereum: { createOnLogin: 'users-without-wallets' } },
      defaultChain: robinhoodChain,
      supportedChains: [robinhoodChain]
    }
  }, React.createElement(AuthBridge));
}

const rootElement = document.getElementById('privy-root');
if (rootElement) createRoot(rootElement).render(React.createElement(Root));

window.addEventListener('unhandledrejection', (event) => {
  console.error('HORMUS Privy module error:', event.reason);
  const box = document.getElementById('login-error');
  if (box && !window.__hormusPrivy?.ready) { box.textContent = 'Sign-in could not load. Please refresh the page.'; box.classList.remove('hidden'); }
});

window.addEventListener('error', (event) => {
  console.error('HORMUS Privy load error:', event.error || event.message);
  const box = document.getElementById('login-error');
  if (box && !window.__hormusPrivy?.ready) {
    box.textContent = 'Sign-in could not load. Please refresh the page.';
    box.classList.remove('hidden');
  }
});
