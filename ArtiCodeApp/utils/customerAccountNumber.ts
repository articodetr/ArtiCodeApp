const MIN_REGULAR_CUSTOMER_ACCOUNT_NUMBER = 1000000;
const MAX_REGULAR_CUSTOMER_ACCOUNT_NUMBER = 9999999;

export const generateRegularCustomerAccountNumber = () =>
  String(
    Math.floor(
      Math.random() *
        (MAX_REGULAR_CUSTOMER_ACCOUNT_NUMBER - MIN_REGULAR_CUSTOMER_ACCOUNT_NUMBER + 1)
    ) + MIN_REGULAR_CUSTOMER_ACCOUNT_NUMBER
  );

export const isCustomerAccountNumberConflict = (error: {
  code?: string;
  message?: string;
  details?: string | null;
} | null | undefined) => {
  if (error?.code !== '23505') {
    return false;
  }

  const errorText = `${error.message ?? ''} ${error.details ?? ''}`.toLowerCase();
  return !errorText || errorText.includes('account_number');
};
