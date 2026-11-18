use std::sync::Arc;

use rootcause::prelude::*;
use tokio::sync::RwLock;

use crate::util::callbacks::TwoFactorCallback;
use crate::{
    anisette::{AnisetteDataGenerator, AnisetteProvider},
    auth::apple_account::AppleAccount,
};

pub struct AppleAccountBuilder {
    email: String,
    anisette_generator: Option<AnisetteDataGenerator>,
    err_429_retries: Option<u32>,
}

impl AppleAccountBuilder {
    /// Create a new AppleAccountBuilder with the given email
    ///
    /// # Arguments
    /// - `email`: The Apple ID email address
    pub fn new(email: &str) -> Self {
        Self {
            email: email.to_string(),
            anisette_generator: None,
            // Zag Store fork: no automatic retries; the app decides.
            err_429_retries: None,
        }
    }

    /// Set the anisette provider. Required: Zag Store's fork has no default server.
    ///
    /// # Arguments
    /// - `anisette_provider`: The anisette provider to use
    pub fn anisette_provider(
        mut self,
        anisette_provider: impl AnisetteProvider + Send + Sync + 'static,
    ) -> Self {
        self.anisette_generator = Some(AnisetteDataGenerator::new(Arc::new(RwLock::new(
            anisette_provider,
        ))));
        self
    }

    /// Sets the number of retries after a 429 Too Many Requests response. Default: none.
    ///
    /// # Errors
    /// Returns an error if the reqwest client cannot be built
    pub fn err_429_retries(mut self, retries: Option<u32>) -> Self {
        self.err_429_retries = retries;
        self
    }

    /// Build the AppleAccount without logging in
    ///
    /// # Errors
    /// Returns an error if the reqwest client cannot be built
    pub async fn build(self) -> Result<AppleAccount, Report> {
        let Some(anisette_generator) = self.anisette_generator else {
            bail!("An anisette provider is required");
        };

        AppleAccount::new(
            &self.email,
            anisette_generator,
            self.err_429_retries,
        )
        .await
    }

    /// Build the AppleAccount and log in
    ///
    /// # Arguments
    /// - `password`: The Apple ID password
    /// - `two_factor_callback`: A callback function that returns the two-factor authentication code
    /// # Errors
    /// Returns an error if the reqwest client cannot be built
    pub async fn login<C>(
        self,
        password: &str,
        two_factor_callback: C,
    ) -> Result<AppleAccount, Report>
    where
        C: TwoFactorCallback,
    {
        let mut account = self.build().await?;
        account.login(password, two_factor_callback).await?;
        Ok(account)
    }
}
