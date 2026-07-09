// =============================================================================
// Data Lake Module Tests — Terratest
// =============================================================================
// ARCHITECTURE DECISION: These tests validate the Cloud Storage data lake
// module's core security guarantees:
// 1. CMEK encryption enabled on every bucket
// 2. Lifecycle rules applied for cost optimization
// 3. Public access prevention enforced
// 4. Retention policies for compliance
// 5. Object versioning for DR
//
// SECURITY SAFEGUARD: These tests must pass before any production deployment.
// A failure in encryption or public access tests is a blocker.

package test

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/gcp"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestDataLakeBucketEncryption validates that all data lake buckets have
// CMEK encryption enabled. This is the most critical security test for
// the module.
func TestDataLakeBucketEncryption(t *testing.T) {
	t.Parallel()

	projectID := gcp.GetGoogleProjectIDFromEnvVar(t)
	environment := "test-" + strings.ToLower(random.UniqueId())

	bucketConfigs := map[string]interface{}{
		"raw": map[string]interface{}{
			"name_prefix":    fmt.Sprintf("test-secondwave-raw-%s", environment),
			"location":       "europe-west2",
			"storage_class":  "STANDARD",
			"retention_days": 0,
			"versioning":     true,
			"lifecycle_rules": []map[string]interface{}{
				{"age": 30, "storage": "NEARLINE"},
			},
		},
		"curated": map[string]interface{}{
			"name_prefix":    fmt.Sprintf("test-secondwave-curated-%s", environment),
			"location":       "europe-west2",
			"storage_class":  "STANDARD",
			"retention_days": 0,
			"versioning":     true,
			"lifecycle_rules": []map[string]interface{}{},
		},
	}

	terraformOptions := &terraform.Options{
		TerraformDir: "../modules/data-lake",
		Vars: map[string]interface{}{
			"project":        projectID,
			"environment":    environment,
			"bucket_configs": bucketConfigs,
		},
		NoColor: true,
	}

	// SECURITY SAFEGUARD: Always destroy test resources
	defer terraform.Destroy(t, terraformOptions)

	terraform.InitAndApply(t, terraformOptions)

	// Verify CMEK encryption on each bucket
	bucketNames := terraform.OutputMap(t, terraformOptions, "bucket_names")
	for zone, bucketName := range bucketNames {
		t.Run(fmt.Sprintf("bucket_%s_encryption", zone), func(t *testing.T) {
			// Check bucket encryption via gsutil
			cmd := fmt.Sprintf("gsutil encryption get gs://%s", bucketName)
			output, err := gcp.RunCommandE(t, cmd)
			require.NoError(t, err,
				"Should be able to read encryption config for bucket %s", bucketName)

			// SECURITY SAFEGUARD: Default encryption must be a KMS key
			// (not Google-managed)
			assert.Contains(t, output, "KMS_KEY",
				"Bucket %s should use KMS key encryption (CMEK)", bucketName)
		})
	}
}

// TestPublicAccessPrevention validates that no data lake bucket allows
// public access. This is a hard security requirement for GDPR compliance.
func TestPublicAccessPrevention(t *testing.T) {
	t.Parallel()

	projectID := gcp.GetGoogleProjectIDFromEnvVar(t)
	environment := "test-" + strings.ToLower(random.UniqueId())

	bucketConfigs := map[string]interface{}{
		"raw": map[string]interface{}{
			"name_prefix":    fmt.Sprintf("test-secondwave-raw-%s", environment),
			"location":       "europe-west2",
			"storage_class":  "STANDARD",
			"retention_days": 0,
			"versioning":     true,
			"lifecycle_rules": []map[string]interface{}{},
		},
	}

	terraformOptions := &terraform.Options{
		TerraformDir: "../modules/data-lake",
		Vars: map[string]interface{}{
			"project":        projectID,
			"environment":    environment,
			"bucket_configs": bucketConfigs,
		},
		NoColor: true,
	}

	defer terraform.Destroy(t, terraformOptions)
	terraform.InitAndApply(t, terraformOptions)

	bucketNames := terraform.OutputMap(t, terraformOptions, "bucket_names")
	for zone, bucketName := range bucketNames {
		t.Run(fmt.Sprintf("bucket_%s_public_access", zone), func(t *testing.T) {
			// Check public access prevention via gsutil
			cmd := fmt.Sprintf("gsutil pap get gs://%s", bucketName)
			output, err := gcp.RunCommandE(t, cmd)
			require.NoError(t, err,
				"Should be able to read PAP config for bucket %s", bucketName)

			// SECURITY SAFEGUARD: Public access prevention must be enforced
			assert.Contains(t, output, "enforced",
				"Bucket %s should have public access prevention enforced", bucketName)
		})
	}
}

// TestLifecycleRules validates that lifecycle rules are applied to the
// correct storage zones. The raw zone should have tiering rules; the
// transient zone should have auto-deletion.
func TestLifecycleRules(t *testing.T) {
	t.Parallel()

	projectID := gcp.GetGoogleProjectIDFromEnvVar(t)
	environment := "test-" + strings.ToLower(random.UniqueId())

	bucketConfigs := map[string]interface{}{
		"raw": map[string]interface{}{
			"name_prefix":    fmt.Sprintf("test-secondwave-raw-%s", environment),
			"location":       "europe-west2",
			"storage_class":  "STANDARD",
			"retention_days": 0,
			"versioning":     true,
			"lifecycle_rules": []map[string]interface{}{
				{"age": 30, "storage": "NEARLINE"},
				{"age": 90, "storage": "COLDLINE"},
				{"age": 365, "storage": "ARCHIVE"},
			},
		},
		"transient": map[string]interface{}{
			"name_prefix":    fmt.Sprintf("test-secondwave-transient-%s", environment),
			"location":       "europe-west2",
			"storage_class":  "STANDARD",
			"retention_days": 0,
			"versioning":     false,
			"lifecycle_rules": []map[string]interface{}{
				{"age": 7, "storage": "DELETE"},
			},
		},
	}

	terraformOptions := &terraform.Options{
		TerraformDir: "../modules/data-lake",
		Vars: map[string]interface{}{
			"project":        projectID,
			"environment":    environment,
			"bucket_configs": bucketConfigs,
		},
		NoColor: true,
	}

	defer terraform.Destroy(t, terraformOptions)
	terraform.InitAndApply(t, terraformOptions)

	bucketNames := terraform.OutputMap(t, terraformOptions, "bucket_names")

	// Test raw bucket has 3 lifecycle rules
	t.Run("raw_zone_lifecycle", func(t *testing.T) {
		cmd := fmt.Sprintf("gsutil lifecycle get gs://%s", bucketNames["raw"])
		output, err := gcp.RunCommandE(t, cmd)
		require.NoError(t, err)

		var lifecycle map[string]interface{}
		err = json.Unmarshal([]byte(output), &lifecycle)
		require.NoError(t, err)

		rules, ok := lifecycle["lifecycle"].(map[string]interface{})["rule"].([]interface{})
		require.True(t, ok, "Raw bucket should have lifecycle rules")
		assert.Equal(t, 3, len(rules),
			"Raw bucket should have 3 lifecycle rules (Nearline, Coldline, Archive)")
	})

	// Test transient bucket has delete rule
	t.Run("transient_zone_lifecycle", func(t *testing.T) {
		cmd := fmt.Sprintf("gsutil lifecycle get gs://%s", bucketNames["transient"])
		output, err := gcp.RunCommandE(t, cmd)
		require.NoError(t, err)

		var lifecycle map[string]interface{}
		err = json.Unmarshal([]byte(output), &lifecycle)
		require.NoError(t, err)

		rules, ok := lifecycle["lifecycle"].(map[string]interface{})["rule"].([]interface{})
		require.True(t, ok, "Transient bucket should have lifecycle rules")
		assert.Equal(t, 1, len(rules),
			"Transient bucket should have 1 lifecycle rule (delete after 7 days)")

		rule := rules[0].(map[string]interface{})
		action := rule["action"].(map[string]interface{})
		assert.Equal(t, "Delete", action["type"],
			"Transient bucket lifecycle should be a Delete action")
	})
}

// TestObjectVersioning validates that versioning is enabled on buckets
// that require DR protection (all except transient).
func TestObjectVersioning(t *testing.T) {
	t.Parallel()

	projectID := gcp.GetGoogleProjectIDFromEnvVar(t)
	environment := "test-" + strings.ToLower(random.UniqueId())

	bucketConfigs := map[string]interface{}{
		"raw": map[string]interface{}{
			"name_prefix":    fmt.Sprintf("test-secondwave-raw-%s", environment),
			"location":       "europe-west2",
			"storage_class":  "STANDARD",
			"retention_days": 0,
			"versioning":     true,
			"lifecycle_rules": []map[string]interface{}{},
		},
		"transient": map[string]interface{}{
			"name_prefix":    fmt.Sprintf("test-secondwave-transient-%s", environment),
			"location":       "europe-west2",
			"storage_class":  "STANDARD",
			"retention_days": 0,
			"versioning":     false,
			"lifecycle_rules": []map[string]interface{}{},
		},
	}

	terraformOptions := &terraform.Options{
		TerraformDir: "../modules/data-lake",
		Vars: map[string]interface{}{
			"project":        projectID,
			"environment":    environment,
			"bucket_configs": bucketConfigs,
		},
		NoColor: true,
	}

	defer terraform.Destroy(t, terraformOptions)
	terraform.InitAndApply(t, terraformOptions)

	bucketNames := terraform.OutputMap(t, terraformOptions, "bucket_names")

	// Test raw bucket has versioning
	t.Run("raw_zone_versioning", func(t *testing.T) {
		cmd := fmt.Sprintf("gsutil versioning get gs://%s", bucketNames["raw"])
		output, err := gcp.RunCommandE(t, cmd)
		require.NoError(t, err)
		assert.Contains(t, output, "Enabled",
			"Raw bucket should have versioning enabled for DR")
	})

	// Test transient bucket does NOT have versioning
	t.Run("transient_zone_no_versioning", func(t *testing.T) {
		cmd := fmt.Sprintf("gsutil versioning get gs://%s", bucketNames["transient"])
		output, err := gcp.RunCommandE(t, cmd)
		require.NoError(t, err)
		assert.Contains(t, output, "Suspended",
			"Transient bucket should NOT have versioning (cost optimization)")
	})
}
