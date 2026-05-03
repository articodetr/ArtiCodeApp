import React, { createContext, useContext, useState, useEffect } from 'react';
import { supabase } from '@/lib/supabase';

interface PinContextType {
  pinRequired: boolean;
  pinVerified: boolean;
  checkingPin: boolean;
  verifyPin: () => void;
  resetPinVerification: () => void;
}

const PinContext = createContext<PinContextType | undefined>(undefined);

export function PinProvider({ children }: { children: React.ReactNode }) {
  const [pinRequired, setPinRequired] = useState(false);
  const [pinVerified, setPinVerified] = useState(false);
  const [checkingPin, setCheckingPin] = useState(true);

  useEffect(() => {
    checkPinStatus();
  }, []);

  const checkPinStatus = async () => {
    try {
      const { data, error } = await supabase
        .from('app_security')
        .select('id')
        .maybeSingle();

      if (error) throw error;

      setPinRequired(!!data);
    } catch (error) {
      console.error('Error checking PIN status:', error);
      setPinRequired(false);
    } finally {
      setCheckingPin(false);
    }
  };

  const verifyPin = () => {
    setPinVerified(true);
  };

  const resetPinVerification = () => {
    setPinVerified(false);
  };

  return (
    <PinContext.Provider
      value={{
        pinRequired,
        pinVerified,
        checkingPin,
        verifyPin,
        resetPinVerification,
      }}
    >
      {children}
    </PinContext.Provider>
  );
}

export function usePin() {
  const context = useContext(PinContext);
  if (context === undefined) {
    throw new Error('usePin must be used within a PinProvider');
  }
  return context;
}
