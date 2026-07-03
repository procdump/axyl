//! Rotate the passphrase that encrypts a node's BLS keystore.

use clap::Args;
use rayls_infrastructure_config::{KeyConfig, RaylsDirs};
use tracing::info;

/// Environment variable that supplies the new passphrase non-interactively.
const NEW_PASSPHRASE_ENVVAR: &str = "RL_BLS_NEW_PASSPHRASE";

/// Re-encrypt the BLS keystore under a new passphrase. The BLS key itself is unchanged,
/// so the node identity and the derived network keys are preserved.
///
/// The current passphrase comes from `--bls-passphrase-source`. The new passphrase is read
/// from `RL_BLS_NEW_PASSPHRASE` if set, otherwise prompted for with confirmation.
#[derive(Debug, Clone, Args)]
pub struct RotatePassphrase {
    /// Only verify the current passphrase decrypts the keystore, without modifying anything.
    #[arg(long = "dry-run")]
    pub dry_run: bool,
}

impl RotatePassphrase {
    /// Rotate the keystore passphrase from `old_passphrase` to a newly sourced one.
    pub fn execute<RLD: RaylsDirs>(
        &self,
        rl_datadir: &RLD,
        old_passphrase: String,
    ) -> eyre::Result<()> {
        // Confirm the current passphrase decrypts the keystore before touching anything.
        let key_config = KeyConfig::read_config(rl_datadir, old_passphrase.clone())?;
        let bls_public_key =
            bs58::encode(&key_config.primary_public_key().to_bytes()[..]).into_string();
        if self.dry_run {
            info!(target: "rl::rotate_passphrase", %bls_public_key, "dry-run: passphrase decrypts the BLS keystore");
            return Ok(());
        }

        let new_passphrase = read_new_passphrase()?;
        KeyConfig::rotate_passphrase(rl_datadir, &old_passphrase, &new_passphrase)?;

        // Read back to confirm the keystore decrypts with the new passphrase.
        KeyConfig::read_config(rl_datadir, new_passphrase)?;
        info!(target: "rl::rotate_passphrase", %bls_public_key, "BLS keystore re-encrypted with the new passphrase");
        Ok(())
    }
}

/// The new passphrase from `RL_BLS_NEW_PASSPHRASE` if set, otherwise prompted with confirmation.
fn read_new_passphrase() -> eyre::Result<String> {
    if let Ok(pw) = std::env::var(NEW_PASSPHRASE_ENVVAR) {
        if !pw.is_empty() {
            return Ok(pw);
        }
    }
    loop {
        let pw = rpassword::prompt_password("Enter the new BLS key passphrase: ")?;
        let pw2 = rpassword::prompt_password("Re-enter the new BLS key passphrase to confirm: ")?;
        if pw == pw2 {
            return if pw.is_empty() { Err(eyre::eyre!("Empty password.")) } else { Ok(pw) };
        }
        println!("Passphrases do not match, retry.");
    }
}
